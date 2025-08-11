variable "zone" {
  description = "The DNS zone resource"
  type = object({
    name = string
  })
}