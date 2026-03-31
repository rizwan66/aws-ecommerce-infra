package test

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/elbv2"
	"github.com/gruntwork-io/terratest/modules/random"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestALBModule verifies the ALB module creates a correctly configured
// internet-facing load balancer with a properly configured target group.
func TestALBModule(t *testing.T) {
	t.Parallel()

	uniqueID := random.UniqueId()
	namePrefix := fmt.Sprintf("test-%s", uniqueID)

	vpcOptions := &terraform.Options{
		TerraformDir: "../../terraform/modules/vpc",
		Vars: map[string]interface{}{
			"name_prefix":          namePrefix,
			"vpc_cidr":             "10.103.0.0/16",
			"availability_zones":   []string{"us-east-1a", "us-east-1b"},
			"public_subnet_cidrs":  []string{"10.103.1.0/24", "10.103.2.0/24"},
			"private_subnet_cidrs": []string{"10.103.11.0/24", "10.103.12.0/24"},
			"data_subnet_cidrs":    []string{"10.103.21.0/24", "10.103.22.0/24"},
		},
		RetryableTerraformErrors: map[string]string{
			"RequestError: send request failed": "Transient error",
		},
		MaxRetries:         3,
		TimeBetweenRetries: 5 * time.Second,
	}
	defer terraform.Destroy(t, vpcOptions)
	terraform.InitAndApply(t, vpcOptions)

	vpcID := terraform.Output(t, vpcOptions, "vpc_id")
	publicSubnetIDs := terraform.OutputList(t, vpcOptions, "public_subnet_ids")

	secOptions := &terraform.Options{
		TerraformDir: "../../terraform/modules/security",
		Vars: map[string]interface{}{
			"name_prefix": namePrefix,
			"vpc_id":      vpcID,
			"vpc_cidr":    "10.103.0.0/16",
		},
	}
	defer terraform.Destroy(t, secOptions)
	terraform.InitAndApply(t, secOptions)

	albSgID := terraform.Output(t, secOptions, "alb_sg_id")

	albOptions := &terraform.Options{
		TerraformDir: "../../terraform/modules/alb",
		Vars: map[string]interface{}{
			"name_prefix":       namePrefix,
			"vpc_id":            vpcID,
			"public_subnet_ids": publicSubnetIDs,
			"alb_sg_id":         albSgID,
		},
	}
	defer terraform.Destroy(t, albOptions)
	terraform.InitAndApply(t, albOptions)

	sess := session.Must(session.NewSession(&aws.Config{Region: aws.String(awsRegion)}))
	elbClient := elbv2.New(sess)

	albARN := terraform.Output(t, albOptions, "alb_arn")
	require.NotEmpty(t, albARN, "ALB ARN should not be empty")

	albDNSName := terraform.Output(t, albOptions, "alb_dns_name")
	require.NotEmpty(t, albDNSName, "ALB DNS name should not be empty")

	// ─── ALB state and scheme ─────────────────────────────────────────────
	albResp, err := elbClient.DescribeLoadBalancersWithContext(context.Background(),
		&elbv2.DescribeLoadBalancersInput{LoadBalancerArns: aws.StringSlice([]string{albARN})})
	require.NoError(t, err)
	require.Len(t, albResp.LoadBalancers, 1)
	alb := albResp.LoadBalancers[0]

	assert.Equal(t, "internet-facing", aws.StringValue(alb.Scheme), "ALB should be internet-facing")
	assert.Equal(t, "application", aws.StringValue(alb.Type), "Should be an Application Load Balancer")
	assert.Equal(t, "active", aws.StringValue(alb.State.Code), "ALB should be in active state")

	// ─── Multi-AZ check ───────────────────────────────────────────────────
	azSet := map[string]bool{}
	for _, az := range alb.AvailabilityZones {
		azSet[aws.StringValue(az.ZoneName)] = true
	}
	assert.GreaterOrEqual(t, len(azSet), 2, "ALB should span at least 2 AZs")

	// ─── Target group assertions ───────────────────────────────────────────
	tgARN := terraform.Output(t, albOptions, "target_group_arn")
	require.NotEmpty(t, tgARN)

	tgResp, err := elbClient.DescribeTargetGroupsWithContext(context.Background(),
		&elbv2.DescribeTargetGroupsInput{TargetGroupArns: aws.StringSlice([]string{tgARN})})
	require.NoError(t, err)
	require.Len(t, tgResp.TargetGroups, 1)
	tg := tgResp.TargetGroups[0]

	assert.Equal(t, "HTTP", aws.StringValue(tg.Protocol))
	assert.Equal(t, int64(8080), aws.Int64Value(tg.Port))
	assert.Equal(t, "/health", aws.StringValue(tg.HealthCheckPath), "Health check path should be /health")
	assert.Equal(t, "200", aws.StringValue(tg.Matcher.HttpCode), "Health check should accept 200")
	assert.LessOrEqual(t, aws.Int64Value(tg.HealthyThresholdCount), int64(3))
	assert.GreaterOrEqual(t, aws.Int64Value(tg.UnhealthyThresholdCount), int64(2))

	// ─── Port 80 listener forwards to app ────────────────────────────────
	listenersResp, err := elbClient.DescribeListenersWithContext(context.Background(),
		&elbv2.DescribeListenersInput{LoadBalancerArn: aws.String(albARN)})
	require.NoError(t, err)

	var port80Listener *elbv2.Listener
	for _, l := range listenersResp.Listeners {
		if aws.Int64Value(l.Port) == 80 {
			port80Listener = l
			break
		}
	}
	require.NotNil(t, port80Listener, "ALB should have a listener on port 80")
	require.NotEmpty(t, port80Listener.DefaultActions)
	assert.Equal(t, "forward", aws.StringValue(port80Listener.DefaultActions[0].Type),
		"Port 80 listener should forward to app (HTTPS redirect requires ACM cert)")

	// ─── Access logging enabled ───────────────────────────────────────────
	attrsResp, err := elbClient.DescribeLoadBalancerAttributesWithContext(context.Background(),
		&elbv2.DescribeLoadBalancerAttributesInput{LoadBalancerArn: aws.String(albARN)})
	require.NoError(t, err)
	accessLogsEnabled := false
	for _, attr := range attrsResp.Attributes {
		if aws.StringValue(attr.Key) == "access_logs.s3.enabled" && aws.StringValue(attr.Value) == "true" {
			accessLogsEnabled = true
		}
	}
	assert.True(t, accessLogsEnabled, "ALB access logging should be enabled")

	// ─── ARN suffix outputs ───────────────────────────────────────────────
	assert.NotEmpty(t, terraform.Output(t, albOptions, "alb_arn_suffix"),
		"ALB ARN suffix required for CloudWatch metrics")
	assert.NotEmpty(t, terraform.Output(t, albOptions, "tg_arn_suffix"),
		"Target group ARN suffix required for CloudWatch metrics")
}

// TestALBDeregistrationDelay verifies the target group has 30s deregistration delay.
func TestALBDeregistrationDelay(t *testing.T) {
	t.Parallel()

	uniqueID := random.UniqueId()
	namePrefix := fmt.Sprintf("test-dereg-%s", uniqueID)

	vpcOptions := &terraform.Options{
		TerraformDir: "../../terraform/modules/vpc",
		Vars: map[string]interface{}{
			"name_prefix":          namePrefix,
			"vpc_cidr":             "10.104.0.0/16",
			"availability_zones":   []string{"us-east-1a", "us-east-1b"},
			"public_subnet_cidrs":  []string{"10.104.1.0/24", "10.104.2.0/24"},
			"private_subnet_cidrs": []string{"10.104.11.0/24", "10.104.12.0/24"},
			"data_subnet_cidrs":    []string{"10.104.21.0/24", "10.104.22.0/24"},
		},
	}
	defer terraform.Destroy(t, vpcOptions)
	terraform.InitAndApply(t, vpcOptions)

	vpcID := terraform.Output(t, vpcOptions, "vpc_id")
	publicSubnetIDs := terraform.OutputList(t, vpcOptions, "public_subnet_ids")

	secOptions := &terraform.Options{
		TerraformDir: "../../terraform/modules/security",
		Vars: map[string]interface{}{
			"name_prefix": namePrefix,
			"vpc_id":      vpcID,
			"vpc_cidr":    "10.104.0.0/16",
		},
	}
	defer terraform.Destroy(t, secOptions)
	terraform.InitAndApply(t, secOptions)

	albOptions := &terraform.Options{
		TerraformDir: "../../terraform/modules/alb",
		Vars: map[string]interface{}{
			"name_prefix":       namePrefix,
			"vpc_id":            vpcID,
			"public_subnet_ids": publicSubnetIDs,
			"alb_sg_id":         terraform.Output(t, secOptions, "alb_sg_id"),
		},
	}
	defer terraform.Destroy(t, albOptions)
	terraform.InitAndApply(t, albOptions)

	tgARN := terraform.Output(t, albOptions, "target_group_arn")

	sess := session.Must(session.NewSession(&aws.Config{Region: aws.String(awsRegion)}))
	elbClient := elbv2.New(sess)

	attrsResp, err := elbClient.DescribeTargetGroupAttributesWithContext(context.Background(),
		&elbv2.DescribeTargetGroupAttributesInput{TargetGroupArn: aws.String(tgARN)})
	require.NoError(t, err)

	var deregDelay string
	for _, attr := range attrsResp.Attributes {
		if aws.StringValue(attr.Key) == "deregistration_delay.timeout_seconds" {
			deregDelay = aws.StringValue(attr.Value)
		}
	}
	assert.Equal(t, "30", deregDelay, "Deregistration delay should be 30s")
}
