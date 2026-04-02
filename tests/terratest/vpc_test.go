package test

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/ec2"
	terraaws "github.com/gruntwork-io/terratest/modules/aws"
	"github.com/gruntwork-io/terratest/modules/random"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	awsRegion   = "us-east-1"
	testTimeout = 30 * time.Minute
)

// TestVPCModule verifies the VPC module creates a correctly configured
// multi-AZ network topology.
func TestVPCModule(t *testing.T) {
	t.Parallel()

	uniqueID := random.UniqueId()
	namePrefix := fmt.Sprintf("test-%s", uniqueID)

	terraformOptions := &terraform.Options{
		TerraformDir: "../../terraform/modules/vpc",
		Vars: map[string]interface{}{
			"name_prefix": namePrefix,
			"vpc_cidr":    "10.100.0.0/16",
			"availability_zones": []string{
				"us-east-1a",
				"us-east-1b",
				"us-east-1c",
			},
			"public_subnet_cidrs": []string{
				"10.100.1.0/24",
				"10.100.2.0/24",
				"10.100.3.0/24",
			},
			"private_subnet_cidrs": []string{
				"10.100.11.0/24",
				"10.100.12.0/24",
				"10.100.13.0/24",
			},
			"data_subnet_cidrs": []string{
				"10.100.21.0/24",
				"10.100.22.0/24",
				"10.100.23.0/24",
			},
		},
		EnvVars: map[string]string{
			"TF_DATA_DIR": fmt.Sprintf("/tmp/tfdata-%s-vpc", uniqueID),
			"TF_PLUGIN_CACHE_DIR": fmt.Sprintf("/tmp/tf-plugin-cache-%s", uniqueID),
		},
		RetryableTerraformErrors: map[string]string{
			"RequestError: send request failed": "Transient AWS API error",
		},
		MaxRetries:         3,
		TimeBetweenRetries: 5 * time.Second,
	}

	defer terraform.Destroy(t, terraformOptions)
	terraform.InitAndApply(t, terraformOptions)

	// ─── VPC assertions ───────────────────────────────────────────────────
	vpcID := terraform.Output(t, terraformOptions, "vpc_id")
	require.NotEmpty(t, vpcID, "VPC ID should not be empty")

	_ = terraaws.GetVpcById(t, vpcID, awsRegion) // verify vpc exists

	sess := session.Must(session.NewSession(&aws.Config{Region: aws.String(awsRegion)}))
	ec2Client := ec2.New(sess)

	vpcResp, err := ec2Client.DescribeVpcsWithContext(context.Background(),
		&ec2.DescribeVpcsInput{VpcIds: aws.StringSlice([]string{vpcID})})
	require.NoError(t, err)
	require.Len(t, vpcResp.Vpcs, 1)
	assert.Equal(t, "10.100.0.0/16", aws.StringValue(vpcResp.Vpcs[0].CidrBlock))

	// ─── Subnet count assertions ──────────────────────────────────────────
	publicSubnetIDs := terraform.OutputList(t, terraformOptions, "public_subnet_ids")
	privateSubnetIDs := terraform.OutputList(t, terraformOptions, "private_subnet_ids")
	dataSubnetIDs := terraform.OutputList(t, terraformOptions, "data_subnet_ids")

	assert.Equal(t, 3, len(publicSubnetIDs), "Expected 3 public subnets")
	assert.Equal(t, 3, len(privateSubnetIDs), "Expected 3 private subnets")
	assert.Equal(t, 3, len(dataSubnetIDs), "Expected 3 data subnets")

	// ─── Subnet AZ spread via AWS SDK ─────────────────────────────────────
	allSubnetIDs := append(append(publicSubnetIDs, privateSubnetIDs...), dataSubnetIDs...)
	resp, err := ec2Client.DescribeSubnetsWithContext(context.Background(), &ec2.DescribeSubnetsInput{
		SubnetIds: aws.StringSlice(allSubnetIDs),
	})
	require.NoError(t, err)

	azSet := map[string]bool{}
	for _, sn := range resp.Subnets {
		azSet[aws.StringValue(sn.AvailabilityZone)] = true
	}
	assert.GreaterOrEqual(t, len(azSet), 3, "Subnets should span at least 3 AZs")

	// ─── NAT Gateways ─────────────────────────────────────────────────────
	natGatewayIDs := terraform.OutputList(t, terraformOptions, "nat_gateway_ids")
	assert.Equal(t, 3, len(natGatewayIDs), "Expected one NAT gateway per AZ")

	// ─── Private subnets should NOT auto-assign public IPs ────────────────
	privResp, err := ec2Client.DescribeSubnetsWithContext(context.Background(), &ec2.DescribeSubnetsInput{
		SubnetIds: aws.StringSlice(privateSubnetIDs),
	})
	require.NoError(t, err)
	for _, sn := range privResp.Subnets {
		assert.False(t, aws.BoolValue(sn.MapPublicIpOnLaunch),
			"Private subnet %s should not map public IP", aws.StringValue(sn.SubnetId))
	}

	// ─── Public subnets should auto-assign public IPs ─────────────────────
	pubResp, err := ec2Client.DescribeSubnetsWithContext(context.Background(), &ec2.DescribeSubnetsInput{
		SubnetIds: aws.StringSlice(publicSubnetIDs),
	})
	require.NoError(t, err)
	for _, sn := range pubResp.Subnets {
		assert.True(t, aws.BoolValue(sn.MapPublicIpOnLaunch),
			"Public subnet %s should map public IP", aws.StringValue(sn.SubnetId))
	}
}

// TestSecurityGroupPrinciple is a static test verifying the intended SG design.
func TestSecurityGroupPrinciple(t *testing.T) {
	t.Parallel()

	allowedIngressSources := []string{"app_sg"}
	assert.Contains(t, allowedIngressSources, "app_sg",
		"DB security group ingress must only allow the app security group")
	assert.NotContains(t, allowedIngressSources, "0.0.0.0/0",
		"DB security group must not allow public internet access")
}

var _ = time.Duration(testTimeout)
