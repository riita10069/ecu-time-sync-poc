variable "name" {
  type    = string
  default = "ecu-time"
}

variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "azs" {
  type    = list(string)
  default = ["ap-northeast-1a", "ap-northeast-1c"]
}

variable "zone_name" {
  description = "既存の Route 53 パブリックホストゾーン"
  type        = string
  default     = "riita.people.aws.dev"
}

variable "subdomain" {
  type    = string
  default = "ecu-time"
}

variable "image_tag" {
  type    = string
  default = "v1"
}

variable "desired_count" {
  type    = number
  default = 2
}

variable "enable_phc" {
  description = "タスクに PHC デバイスを渡す。ECS Managed Instances (m7g.large, 東京) のホストには /dev/ptp0 が無く、true だとタスクが起動しなかった (2026-10-22 確認)"
  type        = bool
  default     = false
}

variable "phc_host_path" {
  type    = string
  default = "/dev/ptp0"
}

variable "instance_types" {
  description = "東京リージョンでは M7g はプレイスメントグループなしでも PHC を使える (legacy access)"
  type        = list(string)
  default     = ["m7g.large"]
}

variable "allowed_vehicles" {
  description = "車両台帳 (PoC では CN のリスト)"
  type        = list(string)
  default     = ["VIN001"]
}

variable "max_offset_ms" {
  description = "ヘルスチェックで許すシステム時計のずれ"
  type        = number
  default     = 1
}
