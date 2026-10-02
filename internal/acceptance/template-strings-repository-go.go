package acceptance

const (
	TemplateStringRepositoryGoHosted = `
resource "nexus_repository_go_hosted" "acceptance" {
` + TemplateStringHostedRepository

	TemplateStringRepositoryGoGroup = `
resource "nexus_repository_go_group" "acceptance" {
	depends_on = [
		nexus_repository_go_proxy.acceptance
	]
` + TemplateStringGroupRepository

	TemplateStringRepositoryGoProxy = `
resource "nexus_repository_go_proxy" "acceptance" {
` + TemplateStringProxyRepository
)
