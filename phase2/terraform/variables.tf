variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region for resources"
  type        = string
  default     = "us-east4"
}

variable "cluster_name" {
  description = "GKE Cluster Name"
  type        = string
  default     = "gke-3tier-prod"
}

variable "authorized_ipv4_cidr" {
  description = "CIDR block authorized to access GKE Master API"
  type        = string
  default     = "0.0.0.0/0"
}
