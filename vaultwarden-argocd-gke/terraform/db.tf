resource "google_compute_global_address" "private_ip_block" {
  name          = "private-ip-block"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  ip_version    = "IPV4"
  prefix_length = 20
  network       = google_compute_network.demolopolis_vpc.self_link
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.demolopolis_vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_block.name]
}

resource "google_sql_database_instance" "vaultwarden_instance" {
  name             = "vaultwarden-db"
  region           = "europe-west3"
  database_version = "POSTGRES_14"

  depends_on = [google_service_networking_connection.private_vpc_connection]

  deletion_protection = false

  settings {
    tier = "db-f1-micro"
    disk_size = 20
    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = google_compute_network.demolopolis_vpc.id
      enable_private_path_for_google_cloud_services = true
    }
  }
}

resource "google_sql_database" "vaultwarden_db" {
  name     = "vaultwarden"
  instance = google_sql_database_instance.vaultwarden_instance.name
}

resource "google_sql_user" "db_user" {
  instance = google_sql_database_instance.vaultwarden_instance.name
  name     = "appuser"
  password = "apppassword"
}
