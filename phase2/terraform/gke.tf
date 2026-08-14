resource "google_container_cluster" "gke_cluster" {
  name                = var.cluster_name
  location            = "${var.region}-a"
  deletion_protection = false

  remove_default_node_pool = true
  initial_node_count       = 1

  node_config {
    machine_type = "n1-standard-1"
  }

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.app_subnet.id

  ip_allocation_policy {
    cluster_secondary_range_name  = "gke-pods"
    services_secondary_range_name = "gke-services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = var.authorized_ipv4_cidr
      display_name = "Admin Authorized CIDR"
    }
  }

  datapath_provider = "ADVANCED_DATAPATH"

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
  }

  release_channel {
    channel = "REGULAR"
  }

  timeouts {
    create = "60m"
    update = "60m"
  }

  depends_on = [google_service_networking_connection.private_vpc_connection]

  lifecycle {
    ignore_changes = [
      node_config,
      node_pool_auto_config,
    ]
  }
}

resource "google_container_node_pool" "app_nodes" {
  name       = "np-app-tier"
  location   = "${var.region}-a"
  cluster    = google_container_cluster.gke_cluster.name
  node_count = 2

  autoscaling {
    min_node_count = 2
    max_node_count = 5
  }

  node_config {
    machine_type = "n1-standard-1"
    spot         = false
    disk_size_gb = 30
    disk_type    = "pd-standard"

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    service_account = google_service_account.gke_node_sa.email

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    labels = {
      tier = "app"
    }

    tags = ["gke-node", "app-tier"]
  }

  lifecycle {
    ignore_changes = [
      node_config[0].resource_labels,
      node_config[0].kubelet_config,
    ]
  }
}
