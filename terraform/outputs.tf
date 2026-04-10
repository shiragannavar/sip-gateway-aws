output "sip_gateway_elastic_ip" {
  description = "Elastic IP of the SIP gateway"
  value       = aws_eip.sip_gateway.public_ip
}

output "sip_gateway_instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.sip_gateway.id
}

output "sip_gateway_private_ip" {
  description = "Private IP of the EC2 instance"
  value       = aws_instance.sip_gateway.private_ip
}

output "sip_uri" {
  description = "SIP URI to configure as outbound trunk address"
  value       = "${aws_eip.sip_gateway.public_ip}:5060"
}

output "sip_uri_tcp" {
  description = "SIP TCP URI for outbound trunk"
  value       = "${aws_eip.sip_gateway.public_ip}:5060;transport=tcp"
}

output "security_group_id" {
  description = "Security group ID for the SIP gateway"
  value       = aws_security_group.sip_signaling.id
}
