# Route tables, NAT gateways and their Elastic IPs.
#
# Routes are declared as separate aws_route resources (not inline `route {}`
# blocks): mixing both styles on one table makes Terraform fight itself, and
# separate routes can be added later (e.g. Transit Gateway) without touching
# the table.

# --- Public: one shared route table, default route to the Internet Gateway ----

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${local.name}-rt-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# --- NAT gateways: one per AZ, or a single shared one ---------------------------

resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)

  domain = "vpc"

  tags = merge(local.tags, { Name = "${local.name}-eip-nat-${local.az_suffix[each.key]}" })
}

resource "aws_nat_gateway" "this" {
  for_each = toset(local.nat_azs)

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id # a NAT lives in a PUBLIC subnet

  tags = merge(local.tags, { Name = "${local.name}-nat-${local.az_suffix[each.key]}" })

  # The NAT needs the IGW attached to reach the internet.
  depends_on = [aws_internet_gateway.this]
}

# --- Private: one route table PER AZ, always --------------------------------
#
# Even in single-NAT mode every AZ keeps its own private route table. Switching
# single_nat_gateway from true to false then only changes where each default
# route points; no route table or subnet association is recreated.

resource "aws_route_table" "private" {
  for_each = toset(var.azs)

  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${local.name}-rt-private-${local.az_suffix[each.key]}" })
}

resource "aws_route" "private_nat" {
  for_each = toset(var.azs)

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[local.nat_for_az[each.key]].id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}
