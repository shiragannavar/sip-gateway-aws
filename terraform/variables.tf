variable "region" {
  description = "AWS region for the SIP gateway"
  type        = string
  default     = "ap-south-1"
}

variable "instance_name" {
  description = "Name tag for the EC2 instance"
  type        = string
  default     = "sip-gateway"
}

variable "instance_type" {
  description = "EC2 instance type (c5.large is good for real-time media)"
  type        = string
  default     = "t3.medium"
}

variable "disk_size_gb" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 20
}

variable "key_name" {
  description = "Name of an existing EC2 key pair for SSH access"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID. Leave empty to use your account's default VPC."
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "Subnet ID (public subnet). Leave empty to auto-select from default VPC."
  type        = string
  default     = ""
}

variable "allowed_sip_source_ranges" {
  description = "CIDR ranges allowed to send SIP traffic. Use 0.0.0.0/0 with digest auth."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssh_source_ranges" {
  description = "CIDR ranges allowed for SSH access"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    Team        = "convai"
    Component   = "sip-gateway"
    Environment = "playground"
  }
}
