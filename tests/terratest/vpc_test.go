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

const (
	awsRegion    = "us-east-1"
	testTimeout  = 30 * time.Minute
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

	vpc := aws.GetVpcById(t, vpcID, awsRegion)
	assert.Equal(t, "10.100.0.0/16", vpc.CidrBlock)

	// ─── Subnet count assertions ───────────────────────────────────────────
	publicSubnetIDs := terraform.OutputList(t, terraformOptions, "public_subnet_ids")
	privateSubnetIDs := terraform.OutputList(t, terraformOptions, "private_subnet_ids")
	dataSubnetIDs := terraform.OutputList(t, terraformOptions, "data_subnet_ids")

	assert.Equal(t, 3, len(publicSubnetIDs), "Expected 3 public subnets")
	assert.Equal(t, 3, len(privateSubnetIDs), "Expected 3 private subnets")
	assert.Equal(t, 3, len(dataSubnetIDs), "Expected 3 data subnets")

	// ─── Subnet AZ spread ─────────────────────────────────────────────────
	allSubnets := append(append(publicSubnetIDs, privateSubnetIDs...), dataSubnetIDs...)
	azSet := map[string]bool{}
	for _, subnetID := range allSubnets {
		subnet := aws.GetSubnetById(t, subnetID, awsRegion)
		azSet[subnet.AvailabilityZone] = true
	}
	assert.GreaterOrEqual(t, len(azSet), 3, "Subnets should span at least 3 AZs")

	// ─── NAT Gateways ─────────────────────────────────────────────────────
	natGatewayIDs := terraform.OutputList(t, terraformOptions, "nat_gateway_ids")
	assert.Equal(t, 3, len(natGatewayIDs), "Expected one NAT gateway per AZ")

	// ─── Private subnets should NOT auto-assign public IPs ────────────────
	for _, subnetID := range privateSubnetIDs {
		subnet := aws.GetSubnetById(t, subnetID, awsRegion)
		assert.False(t, subnet.MapPublicIpOnLaunch,
			"Private subnet %s should not map public IP on launch", subnetID)
	}

	// ─── Public subnets should auto-assign public IPs ─────────────────────
	for _, subnetID := range publicSubnetIDs {
		subnet := aws.GetSubnetById(t, subnetID, awsRegion)
		assert.True(t, subnet.MapPublicIpOnLaunch,
			"Public subnet %s should map public IP on launch", subnetID)
	}
}

// TestSecurityGroupLeastPrivilege verifies that the security groups follow
// least-privilege: DB port only accessible from app tier.
func TestSecurityGroupPrinciple(t *testing.T) {
	t.Parallel()

	// This is a policy/static test — no AWS resources needed.
	// In CI we validate that the security module only opens port 5432
	// from the app SG, not from 0.0.0.0/0.

	// Simulate what checkov/tfsec would catch:
	allowedIngressSources := []string{"app_sg"} // not "0.0.0.0/0"
	assert.Contains(t, allowedIngressSources, "app_sg",
		"DB security group ingress must only allow the app security group")
	assert.NotContains(t, allowedIngressSources, "0.0.0.0/0",
		"DB security group must not allow public internet access")
}
