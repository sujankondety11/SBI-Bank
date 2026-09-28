terraform {
  backend "s3" {
    bucket       = "securebank-terraform-state-sujan-2026"
    key          = "securebank/dev/terraform.tfstate"
    region       = "ap-south-1"
    use_lockfile = true
  }
}