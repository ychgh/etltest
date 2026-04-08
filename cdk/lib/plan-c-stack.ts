import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as actions from 'aws-cdk-lib/aws-cloudwatch-actions';
import { Construct } from 'constructs';

export interface PlanCSpotStackProps extends cdk.StackProps {
  /**
   * EC2 instance type. CPU-only, spot pricing.
   * m5.xlarge  (16 GB, ~$0.041/hr spot) → ~$20/month total  [budget]
   * m5.2xlarge (32 GB, ~$0.082/hr spot) → ~$25/month total  [default ✓]
   * r5.xlarge  (32 GB, ~$0.075/hr spot) → ~$23/month total  [memory-opt]
   */
  instanceType?: ec2.InstanceType;

  /**
   * EBS root volume size in GB.
   * Default: 50
   */
  volumeSizeGb?: number;

  /**
   * CPU% threshold below which the CloudWatch alarm fires (stops instance).
   * Default: 5 (stop after 30 consecutive minutes below 5% CPU)
   */
  idleCpuThreshold?: number;
}

/**
 * Plan C: Cost-optimised spot dev machine with auto-shutdown.
 *
 * Features:
 *  - Persistent spot instance (stops on interruption, EBS preserved)
 *  - Elastic IP (stable address across stop/start)
 *  - CloudWatch alarm: auto-stop after 30 min of CPU < 5%
 *  - In-instance cron: backup auto-shutdown if no SSH sessions for 30 min
 *
 * Target cost: ~$20–$30/month (4 hrs/day × 22 days + GitHub Copilot $10/mo)
 */
export class PlanCSpotStack extends cdk.Stack {
  public readonly instance: ec2.Instance;
  public readonly elasticIp: ec2.CfnEIP;
  public readonly idleAlarm: cloudwatch.Alarm;

  constructor(scope: Construct, id: string, props: PlanCSpotStackProps = {}) {
    super(scope, id, props);

    const instanceType = props.instanceType ?? new ec2.InstanceType('m5.2xlarge');
    const volumeSizeGb = props.volumeSizeGb ?? 50;
    const idleCpuThreshold = props.idleCpuThreshold ?? 5;

    // ── VPC ─────────────────────────────────────────────────────────────────
    const vpc = ec2.Vpc.fromLookup(this, 'DefaultVpc', { isDefault: true });

    // ── Security Group ──────────────────────────────────────────────────────
    const sg = new ec2.SecurityGroup(this, 'SpotDevSG', {
      vpc,
      description: 'Plan C: Spot Dev Machine SG',
      allowAllOutbound: true,
    });
    sg.addIngressRule(ec2.Peer.anyIpv4(), ec2.Port.SSH, 'SSH access');

    // ── IAM Role ────────────────────────────────────────────────────────────
    const role = new iam.Role(this, 'SpotDevRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'),
      ],
    });

    // ── AMI ─────────────────────────────────────────────────────────────────
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
      // Minimal install for cost efficiency
      'apt-get install -y -qq git curl wget tmux htop jq build-essential ' +
        'python3-pip python3-venv docker.io',
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
      // Auto-shutdown: cron-based (backup to CloudWatch alarm)
      'cat > /usr/local/bin/auto-shutdown.sh << \'EOF\'',
      '#!/bin/bash',
      'IDLE_THRESHOLD=1800',
      'SESSIONS=$(who | grep -vc "^$" 2>/dev/null || echo 0)',
      'if [ "$SESSIONS" -eq 0 ]; then',
      '  NOW=$(date +%s)',
      '  LAST_TS=$(last -n 1 ubuntu 2>/dev/null | head -1 | awk \'{print $5" "$6" "$7" "$8}\' | xargs -I{} date -d "{}" +%s 2>/dev/null || echo $((NOW - 100)))',
      '  IDLE=$((NOW - LAST_TS))',
      '  [ "$IDLE" -gt "$IDLE_THRESHOLD" ] && logger "auto-shutdown: idle ${IDLE}s" && shutdown -h now',
      'fi',
      'EOF',
      'chmod +x /usr/local/bin/auto-shutdown.sh',
      '(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/auto-shutdown.sh") | crontab -',
      // tmux default session on login
      'echo \'[ -z "$TMUX" ] && tmux new-session -A -s dev\' >> /home/ubuntu/.bashrc',
    );

    // ── EC2 Instance ────────────────────────────────────────────────────────
    this.instance = new ec2.Instance(this, 'SpotDevInstance', {
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
            deleteOnTermination: false, // preserve data on interruption
            encrypted: true,
          }),
        },
      ],
    });

    // Apply persistent spot market options
    const cfnInstance = this.instance.node.defaultChild as ec2.CfnInstance;
    cfnInstance.instanceMarketOptions = {
      marketType: 'spot',
      spotOptions: {
        spotInstanceType: 'persistent',
        instanceInterruptionBehavior: 'stop',
      },
    };

    // ── Elastic IP ──────────────────────────────────────────────────────────
    this.elasticIp = new ec2.CfnEIP(this, 'SpotDevEIP', {
      domain: 'vpc',
      instanceId: this.instance.instanceId,
      tags: [{ key: 'Name', value: 'dev-spot-c-eip' }],
    });

    // ── CloudWatch Auto-Stop Alarm ──────────────────────────────────────────
    // Stops the instance after 30 minutes (6 × 5-min periods) of CPU < threshold
    this.idleAlarm = new cloudwatch.Alarm(this, 'IdleStopAlarm', {
      alarmName: `dev-spot-c-idle-stop-${this.instance.instanceId}`,
      alarmDescription: `Stop Plan C dev instance after 30 min of CPU < ${idleCpuThreshold}%`,
      metric: new cloudwatch.Metric({
        namespace: 'AWS/EC2',
        metricName: 'CPUUtilization',
        dimensionsMap: { InstanceId: this.instance.instanceId },
        statistic: 'Average',
        period: cdk.Duration.minutes(5),
      }),
      threshold: idleCpuThreshold,
      comparisonOperator: cloudwatch.ComparisonOperator.LESS_THAN_THRESHOLD,
      evaluationPeriods: 6,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });

    // EC2 stop action: arn:aws:automate:<region>:ec2:stop
    this.idleAlarm.addAlarmAction(
      new actions.Ec2InstanceAction(actions.Ec2InstanceActionTarget.STOP),
    );

    // ── Cost Estimate (as CfnOutput) ────────────────────────────────────────
    new cdk.CfnOutput(this, 'InstanceId', {
      value: this.instance.instanceId,
      description: 'Spot Dev Instance ID',
    });

    new cdk.CfnOutput(this, 'ElasticIp', {
      value: this.elasticIp.attrPublicIp,
      description: 'Elastic IP',
    });

    new cdk.CfnOutput(this, 'SshCommand', {
      value: `ssh -i ~/.ssh/your-key.pem ubuntu@${this.elasticIp.attrPublicIp}`,
      description: 'SSH connect command',
    });

    new cdk.CfnOutput(this, 'InstanceType', {
      value: instanceType.toString(),
      description: 'Instance type',
    });

    new cdk.CfnOutput(this, 'MonthlyCostEstimate', {
      value: 'Infrastructure ~$10-15 + GitHub Copilot $10 = ~$20-25/month (4 hrs/day, 22 days)',
      description: 'Estimated monthly cost',
    });

    new cdk.CfnOutput(this, 'IdleAlarmName', {
      value: this.idleAlarm.alarmName,
      description: 'CloudWatch alarm that auto-stops the instance on idle',
    });

    // ── Tags ────────────────────────────────────────────────────────────────
    cdk.Tags.of(this).add('Plan', 'C');
    cdk.Tags.of(this).add('Project', 'etl-devtest');
    cdk.Tags.of(this).add('AutoShutdown', 'enabled');
    cdk.Tags.of(this).add('CostOptimised', 'true');
  }
}
