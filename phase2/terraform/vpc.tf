# VPC Network
resource "google_compute_network" "vpc" {
  name                    = "vpc-3tier-prod"
  auto_create_subnetworks = false
}

# Subnet Tier 1: Web / Ingress
resource "google_compute_subnetwork" "web_subnet" {
  name          = "sb-web-us-central1"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
}

# Subnet Tier 2: App / GKE Private Nodes
resource "google_compute_subnetwork" "app_subnet" {
  name                     = "sb-app-us-central1"
  ip_cidr_range            = "10.0.2.0/24"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "gke-pods"
    ip_cidr_range = "10.100.0.0/16"
  }

  secondary_ip_range {
    range_name    = "gke-services"
    ip_cidr_range = "10.101.0.0/20"
  }
}

# Cloud Router & NAT for Private GKE Worker Nodes outbound egress
resource "google_compute_router" "router" {
  name    = "router-3tier"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "nat-3tier"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# Private Service Access IP Allocation for Tier 3 Cloud SQL
resource "google_compute_global_address" "private_ip_alloc" {
  name          = "psa-cloudsql-ip-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.vpc.id
}

# VPC Peering Connection for Private Service Access
resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_alloc.name]
}
