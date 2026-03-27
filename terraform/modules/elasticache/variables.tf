variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "data_subnet_ids" { type = list(string) }
variable "cache_sg_id" { type = string }
variable "node_type" { type = string }
variable "num_cache_nodes" { type = number }
