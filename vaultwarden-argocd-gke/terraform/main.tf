data "google_project" "project" {
}

resource "google_compute_network" "demolopolis_vpc" {
  name                    = "demolopolis-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "eu_west3_subnet" {
  name          = "europe-west3"
  region        = "europe-west3"
  network       = google_compute_network.demolopolis_vpc.name
  ip_cidr_range = "10.20.30.0/24"
}

resource "google_container_cluster" "demolopolis" {
  name    = "demolopolis"
  network = google_compute_network.demolopolis_vpc.name

  // zonal cluster
  location   = "europe-west3-a"
  subnetwork = google_compute_subnetwork.eu_west3_subnet.name

  // delete the default node pool upon creation
  remove_default_node_pool = true
  initial_node_count       = 1

  // alias IP address instead of using routes
  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {}

  // enable Dataplane v2:
  datapath_provider = "ADVANCED_DATAPATH"

}

resource "google_container_node_pool" "mini_pool" {
  name     = "mini-pool"
  location = "europe-west3-a"
  cluster  = google_container_cluster.demolopolis.name

  node_count = 2
  node_config {
    preemptible  = true
    machine_type = "e2-medium"
    disk_size_gb = "50"
    labels = {
      env = "demo"
    }
  }
}
