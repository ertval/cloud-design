# ------------------------------------------------------------------------------
# VPC Networking: Multi-AZ 3-Tier Architecture
# ------------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # FIX: availability_zones used to default to a hard-coded ["us-east-1a",
  # "us-east-1b"] while aws_region was a variable, so changing the region produced
  # "invalid availability zone" at apply time. An empty variable now means
  # "discover the zones actually offered to this account in this region", and an
  # explicit list is still honoured for operators who pin AZs deliberately.
  availability_zones = length(var.availability_zones) > 0 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 2)
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc"
  })
}

# Internet Gateway for Public Tier
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-igw"
  })
}

# ------------------------------------------------------------------------------
# Subnets
# ------------------------------------------------------------------------------

# 1. Public Subnets (ALB, NAT Gateways)
resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-subnet-${count.index + 1}"
    Tier = "Public"
  })

  # Fail at plan time with a readable message instead of "invalid index" if the
  # AZ list is shorter than the subnet CIDR list.
  lifecycle {
    precondition {
      condition     = length(local.availability_zones) > count.index
      error_message = "public_subnet_cidrs has more entries (${length(var.public_subnet_cidrs)}) than availability_zones (${length(local.availability_zones)}). Supply at least that many zones, or fewer subnet CIDRs."
    }
  }
}

# 2. Private App Subnets (ECS Fargate Tasks)
resource "aws_subnet" "private_app" {
  count                   = length(var.private_app_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_app_subnet_cidrs[count.index]
  availability_zone       = local.availability_zones[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-app-subnet-${count.index + 1}"
    Tier = "Private-App"
  })

  lifecycle {
    precondition {
      condition     = length(local.availability_zones) > count.index
      error_message = "private_app_subnet_cidrs has more entries (${length(var.private_app_subnet_cidrs)}) than availability_zones (${length(local.availability_zones)}). Supply at least that many zones, or fewer subnet CIDRs."
    }
  }
}

# 3. Private DB Subnets (RDS PostgreSQL, Amazon MQ - Isolated from internet)
resource "aws_subnet" "private_db" {
  count                   = length(var.private_db_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_db_subnet_cidrs[count.index]
  availability_zone       = local.availability_zones[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-db-subnet-${count.index + 1}"
    Tier = "Private-DB"
  })

  lifecycle {
    precondition {
      condition     = length(local.availability_zones) > count.index
      error_message = "private_db_subnet_cidrs has more entries (${length(var.private_db_subnet_cidrs)}) than availability_zones (${length(local.availability_zones)}). Supply at least that many zones, or fewer subnet CIDRs."
    }
  }
}

# ------------------------------------------------------------------------------
# NAT Gateways & Elastic IPs
# ------------------------------------------------------------------------------
locals {
  nat_gateway_count = var.single_nat_gateway ? 1 : length(var.public_subnet_cidrs)
}

resource "aws_eip" "nat" {
  count  = local.nat_gateway_count
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nat-eip-${count.index + 1}"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "nat" {
  count         = local.nat_gateway_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nat-gw-${count.index + 1}"
  })

  depends_on = [aws_internet_gateway.main]
}

# ------------------------------------------------------------------------------
# Routing Tables & Associations
# ------------------------------------------------------------------------------

# Public Route Table: Routes 0.0.0.0/0 to Internet Gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-rt"
    Tier = "Public"
  })
}

resource "aws_route_table_association" "public" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private App Route Tables: Route 0.0.0.0/0 to NAT Gateway
resource "aws_route_table" "private_app" {
  count  = length(var.private_app_subnet_cidrs)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.nat[0].id : aws_nat_gateway.nat[count.index].id
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-app-rt-${count.index + 1}"
    Tier = "Private-App"
  })

  lifecycle {
    # Each private app route table indexes aws_nat_gateway.nat[count.index] when
    # single_nat_gateway is false, so the NAT count must cover the subnet count.
    precondition {
      condition     = var.single_nat_gateway || local.nat_gateway_count >= length(var.private_app_subnet_cidrs)
      error_message = "With single_nat_gateway = false there must be at least one NAT Gateway per private app subnet (got ${local.nat_gateway_count} NAT Gateway(s) for ${length(var.private_app_subnet_cidrs)} subnet(s)). Add public_subnet_cidrs entries or set single_nat_gateway = true."
    }
  }
}

resource "aws_route_table_association" "private_app" {
  count          = length(var.private_app_subnet_cidrs)
  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private_app[count.index].id
}

# Private DB Route Table: Completely isolated - no egress route to internet!
resource "aws_route_table" "private_db" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-db-rt"
    Tier = "Private-DB"
  })
}

resource "aws_route_table_association" "private_db" {
  count          = length(var.private_db_subnet_cidrs)
  subnet_id      = aws_subnet.private_db[count.index].id
  route_table_id = aws_route_table.private_db.id
}

# Database Subnet Group for RDS PostgreSQL
resource "aws_db_subnet_group" "main" {
  name        = "${local.name_prefix}-db-subnet-group"
  description = "Subnet group for RDS PostgreSQL across private DB subnets"
  subnet_ids  = aws_subnet.private_db[*].id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-db-subnet-group"
  })
}
