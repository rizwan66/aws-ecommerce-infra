package test

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/ec2"
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

	vpcOptions := &terraform.Options{
		TerraformDir: "../../terraform/modules/vpc",
		Vars: map[string]interface{}{
			"name_prefix": namePrefix,
			"vpc_cidr":             "10.101.0.0/16",
			"availability_zones":   []string{"us-east-1a"}, // single AZ to conserve EIP quota
			"public_subnet_cidrs":  []string{"10.101.1.0/24"},
			"private_subnet_cidrs": []string{"10.101.11.0/24"},
			"data_subnet_cidrs":    []string{"10.101.21.0/24"},
		},
		EnvVars: map[string]string{
			"TF_DATA_DIR": fmt.Sprintf("/tmp/tfdata-%s-vpc", uniqueID),
			"TF_PLUGIN_CACHE_DIR": fmt.Sprintf("/tmp/tf-plugin-cache-%s", uniqueID),
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
		EnvVars: map[string]string{
			"TF_DATA_DIR": fmt.Sprintf("/tmp/tfdata-%s-sec", uniqueID),
			"TF_PLUGIN_CACHE_DIR": fmt.Sprintf("/tmp/tf-plugin-cache-%s", uniqueID),
		},
	}
	defer terraform.Destroy(t, secOptions)
	terraform.InitAndApply(t, secOptions)

	sess := session.Must(session.NewSession(&aws.Config{Region: aws.String(awsRegion)}))
	ec2Client := ec2.New(sess)

	albSgID := terraform.Output(t, secOptions, "alb_sg_id")
	appSgID := terraform.Output(t, secOptions, "app_sg_id")
	dbSgID := terraform.Output(t, secOptions, "db_sg_id")
	cacheSgID := terraform.Output(t, secOptions, "cache_sg_id")

	require.NotEmpty(t, albSgID)
	require.NotEmpty(t, appSgID)
	require.NotEmpty(t, dbSgID)
	require.NotEmpty(t, cacheSgID)

	getSG := func(sgID string) *ec2.SecurityGroup {
		resp, err := ec2Client.DescribeSecurityGroupsWithContext(context.Background(),
			&ec2.DescribeSecurityGroupsInput{GroupIds: aws.StringSlice([]string{sgID})})
		require.NoError(t, err)
		require.Len(t, resp.SecurityGroups, 1)
		return resp.SecurityGroups[0]
	}

	// ─── ALB SG: should accept 80 and 443 from internet ───────────────────
	albSg := getSG(albSgID)
	albPorts := ingressPorts(albSg)
	assert.Contains(t, albPorts, int64(80), "ALB SG should allow port 80")
	assert.Contains(t, albPorts, int64(443), "ALB SG should allow port 443")

	// ─── App SG: should NOT accept direct internet traffic ─────────────────
	appSg := getSG(appSgID)
	assert.False(t, hasCIDRIngress(appSg, "0.0.0.0/0"),
		"App SG must not accept traffic from 0.0.0.0/0")
	assert.True(t, hasSGIngress(appSg, albSgID),
		"App SG must accept traffic from ALB SG")

	// ─── DB SG: port 5432 only from app SG ───────────────────────────────
	dbSg := getSG(dbSgID)
	assert.False(t, hasCIDRIngress(dbSg, "0.0.0.0/0"),
		"DB SG must not be accessible from internet")
	assert.False(t, hasCIDRIngressOnPort(dbSg, "0.0.0.0/0", 5432),
		"DB port 5432 must not be open to internet")
	assert.True(t, hasSGIngressOnPort(dbSg, appSgID, 5432),
		"DB SG must allow port 5432 from App SG")

	// ─── Cache SG: port 6379 only from app SG ─────────────────────────────
	cacheSg := getSG(cacheSgID)
	assert.False(t, hasCIDRIngress(cacheSg, "0.0.0.0/0"),
		"Cache SG must not be accessible from internet")
	assert.True(t, hasSGIngressOnPort(cacheSg, appSgID, 6379),
		"Cache SG must allow port 6379 from App SG")

	// ─── No SSH/RDP open on any SG ────────────────────────────────────────
	for name, sgID := range map[string]string{
		"ALB": albSgID, "App": appSgID, "DB": dbSgID, "Cache": cacheSgID,
	} {
		sg := getSG(sgID)
		assert.False(t, hasCIDRIngressOnPort(sg, "0.0.0.0/0", 22),
			"%s SG must not have SSH open to internet", name)
		assert.False(t, hasCIDRIngressOnPort(sg, "0.0.0.0/0", 3389),
			"%s SG must not have RDP open to internet", name)
	}
}

// TestNoDefaultVPCUsed verifies the module creates a custom VPC, not the default.
func TestNoDefaultVPCUsed(t *testing.T) {
	t.Parallel()

	uniqueID := random.UniqueId()
	vpcOptions := &terraform.Options{
		TerraformDir: "../../terraform/modules/vpc",
		Vars: map[string]interface{}{
			"name_prefix":          fmt.Sprintf("test-%s", uniqueID),
			"vpc_cidr":             "10.102.0.0/16",
			"availability_zones":   []string{"us-east-1b"}, // single AZ to conserve EIP quota
			"public_subnet_cidrs":  []string{"10.102.1.0/24"},
			"private_subnet_cidrs": []string{"10.102.11.0/24"},
			"data_subnet_cidrs":    []string{"10.102.21.0/24"},
		},
		EnvVars: map[string]string{
			"TF_DATA_DIR": fmt.Sprintf("/tmp/tfdata-%s-vpc", uniqueID),
			"TF_PLUGIN_CACHE_DIR": fmt.Sprintf("/tmp/tf-plugin-cache-%s", uniqueID),
		},
	}
	defer terraform.Destroy(t, vpcOptions)
	terraform.InitAndApply(t, vpcOptions)

	vpcID := terraform.Output(t, vpcOptions, "vpc_id")

	sess := session.Must(session.NewSession(&aws.Config{Region: aws.String(awsRegion)}))
	ec2Client := ec2.New(sess)
	resp, err := ec2Client.DescribeVpcsWithContext(context.Background(),
		&ec2.DescribeVpcsInput{VpcIds: aws.StringSlice([]string{vpcID})})
	require.NoError(t, err)
	require.Len(t, resp.Vpcs, 1)

	vpc := resp.Vpcs[0]
	assert.False(t, aws.BoolValue(vpc.IsDefault), "Module must not use the default VPC")
	assert.Equal(t, "10.102.0.0/16", aws.StringValue(vpc.CidrBlock))
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

func ingressPorts(sg *ec2.SecurityGroup) []int64 {
	var ports []int64
	for _, p := range sg.IpPermissions {
		if p.FromPort != nil {
			ports = append(ports, aws.Int64Value(p.FromPort))
		}
	}
	return ports
}

func hasCIDRIngress(sg *ec2.SecurityGroup, cidr string) bool {
	for _, p := range sg.IpPermissions {
		for _, r := range p.IpRanges {
			if aws.StringValue(r.CidrIp) == cidr {
				return true
			}
		}
	}
	return false
}

func hasCIDRIngressOnPort(sg *ec2.SecurityGroup, cidr string, port int64) bool {
	for _, p := range sg.IpPermissions {
		from := aws.Int64Value(p.FromPort)
		to := aws.Int64Value(p.ToPort)
		if from <= port && port <= to {
			for _, r := range p.IpRanges {
				if aws.StringValue(r.CidrIp) == cidr {
					return true
				}
			}
		}
	}
	return false
}

func hasSGIngress(sg *ec2.SecurityGroup, sourceSgID string) bool {
	for _, p := range sg.IpPermissions {
		for _, pair := range p.UserIdGroupPairs {
			if aws.StringValue(pair.GroupId) == sourceSgID {
				return true
			}
		}
	}
	return false
}

func hasSGIngressOnPort(sg *ec2.SecurityGroup, sourceSgID string, port int64) bool {
	for _, p := range sg.IpPermissions {
		from := aws.Int64Value(p.FromPort)
		to := aws.Int64Value(p.ToPort)
		if from <= port && port <= to {
			for _, pair := range p.UserIdGroupPairs {
				if aws.StringValue(pair.GroupId) == sourceSgID {
					return true
				}
			}
		}
	}
	return false
}

var _ = time.Duration(0)
