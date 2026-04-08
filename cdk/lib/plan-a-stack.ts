import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Construct } from 'constructs';

export interface PlanAGpuStackProps extends cdk.StackProps {
  /**
   * EC2 instance type for the GPU machine.
   * Default: g5.xlarge (A10G 24 GB VRAM)
   * Budget option: g4dn.xlarge (T4 16 GB VRAM)
   */
  instanceType?: ec2.InstanceType;

  /**
   * Local LLM model to pull via Ollama on first boot.
   * Default: qwen2.5-coder:14b
   */
  ollamaModel?: string;

  /**
   * EBS root volume size in GB.
   * Default: 100
   */
  volumeSizeGb?: number;
}

/**
 * Plan A: GPU cloud dev machine for running local LLMs.
 *
 * Deploys a persistent spot instance with an NVIDIA GPU, installs
 * Ollama, and pulls a coding-focused LLM (Qwen2.5-Coder by default).
 * An Elastic IP is allocated for a stable address across stop/start cycles.
 *
 * Estimated cost: ~$26–$52/month (4 hrs/day, g4dn.xlarge–g5.xlarge spot)
 */
export class PlanAGpuStack extends cdk.Stack {
  public readonly instance: ec2.Instance;
  public readonly elasticIp: ec2.CfnEIP;

  constructor(scope: Construct, id: string, props: PlanAGpuStackProps = {}) {
    super(scope, id, props);

    const instanceType = props.instanceType ?? new ec2.InstanceType('g5.xlarge');
    const ollamaModel = props.ollamaModel ?? 'qwen2.5-coder:14b';
    const volumeSizeGb = props.volumeSizeGb ?? 100;

    // ── VPC (default) ───────────────────────────────────────────────────────
    const vpc = ec2.Vpc.fromLookup(this, 'DefaultVpc', { isDefault: true });

    // ── Security Group ──────────────────────────────────────────────────────
    const sg = new ec2.SecurityGroup(this, 'GpuDevSG', {
      vpc,
      description: 'Plan A: GPU Dev Machine SG',
      allowAllOutbound: true,
    });
    // SSH access — restrict to your IP in production using
    // sg.addIngressRule(ec2.Peer.ipv4('x.x.x.x/32'), ec2.Port.SSH)
    sg.addIngressRule(ec2.Peer.anyIpv4(), ec2.Port.SSH, 'SSH access');

    // ── IAM Role ────────────────────────────────────────────────────────────
    const role = new iam.Role(this, 'GpuDevRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'),
      ],
    });

    // ── AMI (Deep Learning / Ubuntu 22.04) ──────────────────────────────────
    const ami = ec2.MachineImage.lookup({
      name: 'ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*',
      owners: ['099720109477'], // Canonical
    });

    // ── User Data ───────────────────────────────────────────────────────────
    const userData = ec2.UserData.forLinux();
    userData.addCommands(
      'set -euo pipefail',
      'export DEBIAN_FRONTEND=noninteractive',
      'apt-get update -qq && apt-get upgrade -y -qq',
      'apt-get install -y -qq git curl wget tmux htop build-essential python3-pip docker.io',
      'usermod -aG docker ubuntu',
      // Install NVIDIA drivers
      'apt-get install -y ubuntu-drivers-common',
      'ubuntu-drivers autoinstall || true',
      // Install Ollama
      'curl -fsSL https://ollama.ai/install.sh | sh',
      'systemctl enable ollama && systemctl start ollama',
      'sleep 5',
      // Pull model
      `sudo -u ubuntu ollama pull ${ollamaModel} || true`,
      // Auto-shutdown
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
    this.instance = new ec2.Instance(this, 'GpuDevInstance', {
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

    // Note: CDK L2 does not natively support spot instance market options.
    // To use spot pricing, use CfnInstance with LaunchTemplate, or use
    // the escape hatch: (this.instance.node.defaultChild as ec2.CfnInstance)
    const cfnInstance = this.instance.node.defaultChild as ec2.CfnInstance;
    cfnInstance.instanceMarketOptions = {
      marketType: 'spot',
      spotOptions: {
        spotInstanceType: 'persistent',
        instanceInterruptionBehavior: 'stop',
      },
    };

    // ── Elastic IP ──────────────────────────────────────────────────────────
    this.elasticIp = new ec2.CfnEIP(this, 'GpuDevEIP', {
      domain: 'vpc',
      instanceId: this.instance.instanceId,
      tags: [{ key: 'Name', value: 'llm-gpu-dev-eip' }],
    });

    // ── Outputs ─────────────────────────────────────────────────────────────
    new cdk.CfnOutput(this, 'InstanceId', {
      value: this.instance.instanceId,
      description: 'GPU Dev Instance ID',
    });

    new cdk.CfnOutput(this, 'ElasticIp', {
      value: this.elasticIp.attrPublicIp,
      description: 'Elastic IP (stable SSH address)',
    });

    new cdk.CfnOutput(this, 'SshCommand', {
      value: `ssh -i ~/.ssh/your-key.pem ubuntu@${this.elasticIp.attrPublicIp}`,
      description: 'SSH connect command',
    });

    new cdk.CfnOutput(this, 'OllamaTunnel', {
      value: `ssh -L 11434:localhost:11434 ubuntu@${this.elasticIp.attrPublicIp} -N`,
      description: 'SSH tunnel for Ollama API (then use http://localhost:11434)',
    });

    // ── Tags ────────────────────────────────────────────────────────────────
    cdk.Tags.of(this).add('Plan', 'A');
    cdk.Tags.of(this).add('Project', 'etl-devtest');
  }
}
