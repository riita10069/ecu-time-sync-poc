# 公開 NLB。UDP 123 は車両が携帯網からインターネット越しに使うので送信元を絞れない。
# NTS の cookie がない要求には ntpd-rs が DENY を返す (require-nts = "deny")
resource "aws_security_group" "public_nlb" {
  name   = "${var.name}-public-nlb"
  vpc_id = aws_vpc.main.id
  ingress {
    description = "NTS-protected NTP from vehicles"
    protocol    = "udp"
    from_port   = 123
    to_port     = 123
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
}

# 内部 NLB。NTS-KE (TCP 4460) は Lambda からだけ受ける。
# ここに届けばトークンなしの通常の NTS-KE でも cookie が出るため、絶対に公開しない
resource "aws_security_group" "internal_nlb" {
  name   = "${var.name}-internal-nlb"
  vpc_id = aws_vpc.main.id
  ingress {
    description     = "NTS-KE from Lambda only"
    protocol        = "tcp"
    from_port       = 4460
    to_port         = 4460
    security_groups = [aws_security_group.lambda.id]
  }
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
}

resource "aws_security_group" "lambda" {
  name   = "${var.name}-lambda"
  vpc_id = aws_vpc.main.id
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "task" {
  name   = "${var.name}-task"
  vpc_id = aws_vpc.main.id
  ingress {
    description     = "NTP from public NLB"
    protocol        = "udp"
    from_port       = 123
    to_port         = 123
    security_groups = [aws_security_group.public_nlb.id]
  }
  ingress {
    description     = "NTS-KE from internal NLB"
    protocol        = "tcp"
    from_port       = 4460
    to_port         = 4460
    security_groups = [aws_security_group.internal_nlb.id]
  }
  ingress {
    description     = "health check from NLBs"
    protocol        = "tcp"
    from_port       = 8080
    to_port         = 8080
    security_groups = [aws_security_group.public_nlb.id, aws_security_group.internal_nlb.id]
  }
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "instances" {
  name   = "${var.name}-instances"
  vpc_id = aws_vpc.main.id
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}
