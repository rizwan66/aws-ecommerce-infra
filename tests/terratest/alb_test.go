package test

import (
	"fmt"
	"testing"
	"time"

	"github.com/gruntwork-io/terratest/modules/aws"
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

	// Bootstrap: VPC + subnets first
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

	// Security group for ALB
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

	// ALB module
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

	// ─── ALB assertions ───────────────────────────────────────────────────
	albDNSName := terraform.Output(t, albOptions, "alb_dns_name")
	require.NotEmpty(t, albDNSName, "ALB DNS name should not be empty")

	albARN := terraform.Output(t, albOptions, "alb_arn")
	require.NotEmpty(t, albARN, "ALB ARN should not be empty")

	// Verify ALB exists in AWS
	alb := aws.GetLoadBalancer(t, albARN, awsRegion)
	assert.Equal(t, "internet-facing", *alb.Scheme,
		"ALB should be internet-facing")
	assert.Equal(t, "application", *alb.Type,
		"Should be an Application Load Balancer")
	assert.Equal(t, "active", *alb.State.Code,
		"ALB should be in active state")

	// ─── Multi-AZ check ───────────────────────────────────────────────────
	azSet := map[string]bool{}
	for _, az := range alb.AvailabilityZones {
		azSet[*az.ZoneName] = true
	}
	assert.GreaterOrEqual(t, len(azSet), 2,
		"ALB should span at least 2 AZs")

	// ─── Target group assertions ───────────────────────────────────────────
	tgARN := terraform.Output(t, albOptions, "target_group_arn")
	require.NotEmpty(t, tgARN)

	tg := aws.GetTargetGroup(t, tgARN, awsRegion)
	assert.Equal(t, "HTTP", *tg.Protocol)
	assert.Equal(t, int64(8080), *tg.Port)

	// Health check config
	hc := tg.HealthCheckConfiguration
	require.NotNil(t, hc)
	assert.Equal(t, "/health", *hc.Path,
		"Health check path should be /health")
	assert.Equal(t, "HTTP", *hc.Protocol)
	assert.Equal(t, "200", *hc.Matcher.HttpCode,
		"Health check matcher should accept only 200")
	assert.LessOrEqual(t, *hc.HealthyThresholdCount, int64(3),
		"Should mark healthy quickly (≤3 checks)")
	assert.GreaterOrEqual(t, *hc.UnhealthyThresholdCount, int64(2),
		"Should require ≥2 failures before marking unhealthy")

	// ─── HTTP → HTTPS redirect ────────────────────────────────────────────
	listeners := aws.GetListeners(t, albARN, awsRegion)
	var httpListener *aws.Listener
	for _, l := range listeners {
		if *l.Port == 80 {
			httpListener = &l
			break
		}
	}
	require.NotNil(t, httpListener, "ALB should have a listener on port 80")
	require.NotEmpty(t, httpListener.DefaultActions)
	assert.Equal(t, "redirect", *httpListener.DefaultActions[0].Type,
		"Port 80 listener should redirect (not forward)")

	// ─── Access logging enabled ───────────────────────────────────────────
	attrs := aws.GetLoadBalancerAttributes(t, albARN, awsRegion)
	accessLogsEnabled := false
	for _, attr := range attrs {
		if *attr.Key == "access_logs.s3.enabled" && *attr.Value == "true" {
			accessLogsEnabled = true
		}
	}
	assert.True(t, accessLogsEnabled, "ALB access logging should be enabled")

	// ─── ARN suffix output ────────────────────────────────────────────────
	albARNSuffix := terraform.Output(t, albOptions, "alb_arn_suffix")
	assert.NotEmpty(t, albARNSuffix, "ALB ARN suffix required for CloudWatch metrics")

	tgARNSuffix := terraform.Output(t, albOptions, "tg_arn_suffix")
	assert.NotEmpty(t, tgARNSuffix, "Target group ARN suffix required for CloudWatch metrics")
}

// TestALBDeregistrationDelay verifies the target group has a reasonable
// deregistration delay (30s) to allow in-flight requests to complete.
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
	tgAttrs := aws.GetTargetGroupAttributes(t, tgARN, awsRegion)

	var deregDelay string
	for _, attr := range tgAttrs {
		if *attr.Key == "deregistration_delay.timeout_seconds" {
			deregDelay = *attr.Value
		}
	}
	assert.Equal(t, "30", deregDelay,
		"Deregistration delay should be 30s to drain connections gracefully")
}
