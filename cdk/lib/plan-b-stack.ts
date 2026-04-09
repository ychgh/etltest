import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Construct } from 'constructs';

export interface PlanBCpuStackProps extends cdk.StackProps {
  /**
   * EC2 instance type. Should be CPU-only (no GPU needed).
   * 32 GB: m5.2xlarge (default)  — balanced
   * 64 GB: r5.2xlarge             — memory-heavy workloads
   * 64 GB: m5.4xlarge             — CPU + memory
   */
  instanceType?: ec2.InstanceType;

  /**
   * Use spot pricing.
   * Default: false (On-Demand for predictable availability)
   * Set true for ~80% cost reduction with potential interruptions.
   */
  useSpot?: boolean;

  /**
   * EBS root volume size in GB.
   * Default: 50
   */
  volumeSizeGb?: number;
}

/**
 * Plan B: CPU-only EC2 dev machine + cloud LLM subscription.
 *
 * Deploys a general-purpose EC2 instance (no GPU) pre-configured as
 * a development environment. LLM assistance comes from a cloud
 * subscription (GitHub Copilot Pro $10/mo or OpenCode Zen pay-as-you-go).
 *
 * Estimated cost:
 *   On-Demand m5.2xlarge: ~$50/month (4 hrs/day) + $10 Copilot
 *   Spot m5.2xlarge:      ~$23/month (4 hrs/day) + $10 Copilot
 */
export class PlanBCpuStack extends cdk.Stack {
  public readonly instance: ec2.Instance;
  public readonly elasticIp: ec2.CfnEIP;

  constructor(scope: Construct, id: string, props: PlanBCpuStackProps = {}) {
    super(scope, id, props);

    const instanceType = props.instanceType ?? new ec2.InstanceType('m5.2xlarge');
    const useSpot = props.useSpot ?? false;
    const volumeSizeGb = props.volumeSizeGb ?? 50;

    // ── VPC (default) ───────────────────────────────────────────────────────
    const vpc = ec2.Vpc.fromLookup(this, 'DefaultVpc', { isDefault: true });

    // ── Security Group ──────────────────────────────────────────────────────
    const sg = new ec2.SecurityGroup(this, 'DevMachineSG', {
      vpc,
      description: 'Plan B: CPU Dev Machine SG',
      allowAllOutbound: true,
    });
    sg.addIngressRule(ec2.Peer.anyIpv4(), ec2.Port.SSH, 'SSH access');

    // ── IAM Role ────────────────────────────────────────────────────────────
    const role = new iam.Role(this, 'DevMachineRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'),
      ],
    });

    // ── AMI (Ubuntu 22.04 LTS) ──────────────────────────────────────────────
    const ami = ec2.MachineImage.lookup({
      name: 'ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*',
      owners: ['099720109477'],
    });

    // ── User Data ───────────────────────────────────────────────────────────
    const userData = ec2.UserData.forLinux();
    userData.addCommands(
      'set -euo pipefail',
      'export DEBIAN_FRONTEND=noninteractive',
      'apt-get update -qq && apt-get upgrade -y -qq',
      'apt-get install -y -qq git curl wget tmux htop neovim vim build-essential ' +
        'python3-pip python3-venv docker.io docker-compose-v2 jq awscli shellcheck',
      'usermod -aG docker ubuntu',
      // Node.js 20
      'curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null',
      'apt-get install -y nodejs',
      // GitHub CLI
      'mkdir -p -m 755 /etc/apt/keyrings',
      'wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg ' +
        '| tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null',
      'chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg',
      'echo "deb [arch=$(dpkg --print-architecture) ' +
        'signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] ' +
        'https://cli.github.com/packages stable main" ' +
        '| tee /etc/apt/sources.list.d/github-cli.list > /dev/null',
      'apt-get update -qq && apt-get install -y gh',
      // OpenCode
      'npm install -g opencode-ai 2>/dev/null || true',
      // tmux config
      'sudo -u ubuntu bash -c \'cat > ~/.tmux.conf << "TMUX"\n' +
        'set -g mouse on\nset -g history-limit 10000\n' +
        'bind | split-window -h\nbind - split-window -v\n' +
        'TMUX\'',
      // Auto-shutdown on idle
      'cat > /usr/local/bin/auto-shutdown.sh << \'EOF\'',
      '#!/bin/bash',
      'IDLE_THRESHOLD=1800',
      'SESSIONS=$(who | grep -vc "^$" 2>/dev/null || echo 0)',
      'if [ "$SESSIONS" -eq 0 ]; then',
      '  NOW=$(date +%s)',
      '  LAST_TS=$(last -n 1 ubuntu 2>/dev/null | head -1 | awk \'{print $5" "$6" "$7" "$8}\' | xargs -I{} date -d "{}" +%s 2>/dev/null || echo $((NOW - 100)))',
      '  IDLE=$((NOW - LAST_TS))',
      '  [ "$IDLE" -gt "$IDLE_THRESHOLD" ] && logger "auto-shutdown" && shutdown -h now',
      'fi',
      'EOF',
      'chmod +x /usr/local/bin/auto-shutdown.sh',
      '(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/auto-shutdown.sh") | crontab -',
    );

    // ── EC2 Instance ────────────────────────────────────────────────────────
    this.instance = new ec2.Instance(this, 'DevMachineInstance', {
      vpc,
      instanceType,
      machineImage: ami,
      securityGroup: sg,
      role,
      userData,
      blockDevices: [
        {
          deviceName: '/dev/sda1',
          volume: ec2.BlockDeviceVolume.ebs(volumeSizeGb, {
            volumeType: ec2.EbsDeviceVolumeType.GP3,
            deleteOnTermination: false,
            encrypted: true,
          }),
        },
      ],
    });

    // Apply spot market options if requested
    if (useSpot) {
      const cfnInstance = this.instance.node.defaultChild as ec2.CfnInstance;
      cfnInstance.instanceMarketOptions = {
        marketType: 'spot',
        spotOptions: {
          spotInstanceType: 'persistent',
          instanceInterruptionBehavior: 'stop',
        },
      };
    }

    // ── Elastic IP ──────────────────────────────────────────────────────────
    this.elasticIp = new ec2.CfnEIP(this, 'DevMachineEIP', {
      domain: 'vpc',
      instanceId: this.instance.instanceId,
      tags: [{ key: 'Name', value: 'dev-machine-b-eip' }],
    });

    // ── Outputs ─────────────────────────────────────────────────────────────
    new cdk.CfnOutput(this, 'InstanceId', {
      value: this.instance.instanceId,
      description: 'Dev Machine Instance ID',
    });

    new cdk.CfnOutput(this, 'ElasticIp', {
      value: this.elasticIp.attrPublicIp,
      description: 'Elastic IP for SSH',
    });

    new cdk.CfnOutput(this, 'SshCommand', {
      value: `ssh -i ~/.ssh/your-key.pem ubuntu@${this.elasticIp.attrPublicIp}`,
      description: 'SSH connect command',
    });

    new cdk.CfnOutput(this, 'SshConfigEntry', {
      value: [
        'Host devmachine-b',
        `    HostName ${this.elasticIp.attrPublicIp}`,
        '    User ubuntu',
        '    IdentityFile ~/.ssh/your-key.pem',
        '    ServerAliveInterval 60',
      ].join('\n'),
      description: '~/.ssh/config entry for VS Code Remote-SSH',
    });

    new cdk.CfnOutput(this, 'InstanceType', {
      value: instanceType.toString(),
      description: 'Instance type',
    });

    new cdk.CfnOutput(this, 'SpotEnabled', {
      value: String(useSpot),
      description: 'Spot pricing enabled',
    });

    // ── Tags ────────────────────────────────────────────────────────────────
    cdk.Tags.of(this).add('Plan', 'B');
    cdk.Tags.of(this).add('Project', 'etl-devtest');
  }
}
