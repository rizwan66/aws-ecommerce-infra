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

// TestSecurityGroupModule verifies that the security module creates
// the correct least-privilege rules between tiers.
func TestSecurityGroupModule(t *testing.T) {
	t.Parallel()

	uniqueID := random.UniqueId()
	namePrefix := fmt.Sprintf("test-%s", uniqueID)

	// First create VPC (security module depends on vpc_id)
	vpcOptions := &terraform.Options{
		TerraformDir: "../../terraform/modules/vpc",
		Vars: map[string]interface{}{
			"name_prefix": namePrefix,
			"vpc_cidr":    "10.101.0.0/16",
			"availability_zones": []string{
				"us-east-1a", "us-east-1b",
			},
			"public_subnet_cidrs":  []string{"10.101.1.0/24", "10.101.2.0/24"},
			"private_subnet_cidrs": []string{"10.101.11.0/24", "10.101.12.0/24"},
			"data_subnet_cidrs":    []string{"10.101.21.0/24", "10.101.22.0/24"},
		},
	}
	defer terraform.Destroy(t, vpcOptions)
	terraform.InitAndApply(t, vpcOptions)

	vpcID := terraform.Output(t, vpcOptions, "vpc_id")

	secOptions := &terraform.Options{
		TerraformDir: "../../terraform/modules/security",
		Vars: map[string]interface{}{
			"name_prefix": namePrefix,
			"vpc_id":      vpcID,
			"vpc_cidr":    "10.101.0.0/16",
		},
	}
	defer terraform.Destroy(t, secOptions)
	terraform.InitAndApply(t, secOptions)

	// ─── ALB SG: should accept 80 and 443 from internet ───────────────────
	albSgID := terraform.Output(t, secOptions, "alb_sg_id")
	require.NotEmpty(t, albSgID)

	albSg := aws.GetSecurityGroupById(t, albSgID, awsRegion)
	assert.Equal(t, vpcID, *albSg.VpcId)

	albIngressPorts := extractIngressPorts(albSg)
	assert.Contains(t, albIngressPorts, int64(80), "ALB SG should allow port 80")
	assert.Contains(t, albIngressPorts, int64(443), "ALB SG should allow port 443")

	// ─── App SG: should NOT accept direct internet traffic ─────────────────
	appSgID := terraform.Output(t, secOptions, "app_sg_id")
	require.NotEmpty(t, appSgID)

	appSg := aws.GetSecurityGroupById(t, appSgID, awsRegion)
	assert.False(
		t,
		hasIngressFromCidr(appSg, "0.0.0.0/0"),
		"App SG must not accept traffic from 0.0.0.0/0 (internet)",
	)
	assert.True(
		t,
		hasIngressFromSG(appSg, albSgID),
		"App SG must accept traffic from ALB SG",
	)

	// ─── DB SG: only from app SG on 5432 ──────────────────────────────────
	dbSgID := terraform.Output(t, secOptions, "db_sg_id")
	require.NotEmpty(t, dbSgID)

	dbSg := aws.GetSecurityGroupById(t, dbSgID, awsRegion)
	assert.False(
		t,
		hasIngressFromCidr(dbSg, "0.0.0.0/0"),
		"DB SG must not be accessible from internet",
	)
	assert.False(
		t,
		hasPortOpenFromCidr(dbSg, 5432, "0.0.0.0/0"),
		"DB port 5432 must not be open to internet",
	)
	assert.True(
		t,
		hasIngressFromSGOnPort(dbSg, appSgID, 5432),
		"DB SG must allow port 5432 from App SG",
	)

	// ─── Cache SG: only from app SG on 6379 ───────────────────────────────
	cacheSgID := terraform.Output(t, secOptions, "cache_sg_id")
	require.NotEmpty(t, cacheSgID)

	cacheSg := aws.GetSecurityGroupById(t, cacheSgID, awsRegion)
	assert.False(
		t,
		hasIngressFromCidr(cacheSg, "0.0.0.0/0"),
		"Cache SG must not be accessible from internet",
	)
	assert.True(
		t,
		hasIngressFromSGOnPort(cacheSg, appSgID, 6379),
		"Cache SG must allow port 6379 from App SG",
	)

	// ─── No SSH (22) or RDP (3389) open on any SG ─────────────────────────
	for name, sgID := range map[string]string{
		"ALB":   albSgID,
		"App":   appSgID,
		"DB":    dbSgID,
		"Cache": cacheSgID,
	} {
		sg := aws.GetSecurityGroupById(t, sgID, awsRegion)
		assert.False(t, hasPortOpenFromCidr(sg, 22, "0.0.0.0/0"),
			"%s SG must not have SSH (22) open to internet", name)
		assert.False(t, hasPortOpenFromCidr(sg, 3389, "0.0.0.0/0"),
			"%s SG must not have RDP (3389) open to internet", name)
	}
}

// TestNoDefaultVPCUsed verifies that the project uses a custom VPC,
// not the AWS default VPC (which has permissive rules).
func TestNoDefaultVPCUsed(t *testing.T) {
	t.Parallel()

	// The test VPC is created by our module — verify it's not the default VPC
	uniqueID := random.UniqueId()
	vpcOptions := &terraform.Options{
		TerraformDir: "../../terraform/modules/vpc",
		Vars: map[string]interface{}{
			"name_prefix":          fmt.Sprintf("test-%s", uniqueID),
			"vpc_cidr":             "10.102.0.0/16",
			"availability_zones":   []string{"us-east-1a", "us-east-1b"},
			"public_subnet_cidrs":  []string{"10.102.1.0/24", "10.102.2.0/24"},
			"private_subnet_cidrs": []string{"10.102.11.0/24", "10.102.12.0/24"},
			"data_subnet_cidrs":    []string{"10.102.21.0/24", "10.102.22.0/24"},
		},
	}
	defer terraform.Destroy(t, vpcOptions)
	terraform.InitAndApply(t, vpcOptions)

	vpcID := terraform.Output(t, vpcOptions, "vpc_id")
	vpc := aws.GetVpcById(t, vpcID, awsRegion)

	// Default VPC has isDefault=true and CIDR 172.31.0.0/16
	assert.False(t, *vpc.IsDefault, "Module must not use the default VPC")
	assert.Equal(t, "10.102.0.0/16", vpc.CidrBlock, "VPC CIDR should match input variable")
}

// ─── Helper functions ─────────────────────────────────────────────────────────

func extractIngressPorts(sg *aws.SecurityGroup) []int64 {
	var ports []int64
	for _, perm := range sg.IpPermissions {
		if perm.FromPort != nil {
			ports = append(ports, *perm.FromPort)
		}
		if perm.ToPort != nil && *perm.ToPort != *perm.FromPort {
			ports = append(ports, *perm.ToPort)
		}
	}
	return ports
}

func hasIngressFromCidr(sg *aws.SecurityGroup, cidr string) bool {
	for _, perm := range sg.IpPermissions {
		for _, ipRange := range perm.IpRanges {
			if ipRange.CidrIp != nil && *ipRange.CidrIp == cidr {
				return true
			}
		}
	}
	return false
}

func hasPortOpenFromCidr(sg *aws.SecurityGroup, port int64, cidr string) bool {
	for _, perm := range sg.IpPermissions {
		if perm.FromPort != nil && *perm.FromPort <= port &&
			perm.ToPort != nil && *perm.ToPort >= port {
			for _, ipRange := range perm.IpRanges {
				if ipRange.CidrIp != nil && *ipRange.CidrIp == cidr {
					return true
				}
			}
		}
	}
	return false
}

func hasIngressFromSG(sg *aws.SecurityGroup, sourceSgID string) bool {
	for _, perm := range sg.IpPermissions {
		for _, pair := range perm.UserIdGroupPairs {
			if pair.GroupId != nil && *pair.GroupId == sourceSgID {
				return true
			}
		}
	}
	return false
}

func hasIngressFromSGOnPort(sg *aws.SecurityGroup, sourceSgID string, port int64) bool {
	for _, perm := range sg.IpPermissions {
		if perm.FromPort != nil && *perm.FromPort <= port &&
			perm.ToPort != nil && *perm.ToPort >= port {
			for _, pair := range perm.UserIdGroupPairs {
				if pair.GroupId != nil && *pair.GroupId == sourceSgID {
					return true
				}
			}
		}
	}
	return false
}

// Ensure test timeout doesn't exceed 30 minutes
var _ = time.Duration(testTimeout)
