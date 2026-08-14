output "gke_cluster_name" {
  value = google_container_cluster.gke_cluster.name
}

output "gke_get_credentials_command" {
  value = "gcloud container clusters get-credentials ${google_container_cluster.gke_cluster.name} --zone ${var.region}-a --project ${var.project_id}"
}

output "cloudsql_private_ip" {
  value = google_sql_database_instance.postgres.private_ip_address
}

output "cloudsql_connection_name" {
  value = google_sql_database_instance.postgres.connection_name
}

output "db_password" {
  value     = random_password.db_password.result
  sensitive = true
}
