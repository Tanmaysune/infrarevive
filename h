{
    "Reservations": [
        {
            "ReservationId": "r-08ecb25dcab2668e9",
            "OwnerId": "916923735515",
            "Groups": [],
            "Instances": [
                {
                    "Architecture": "x86_64",
                    "BlockDeviceMappings": [
                        {
                            "DeviceName": "/dev/xvda",
                            "Ebs": {
                                "AttachTime": "2026-07-22T14:51:02+00:00",
                                "DeleteOnTermination": true,
                                "Status": "attached",
                                "VolumeId": "vol-0122e02cee085dee3",
                                "EbsCardIndex": 0
                            }
                        }
                    ],
                    "ClientToken": "terraform-20260722145101967500000004",
                    "EbsOptimized": false,
                    "EnaSupport": true,
                    "Hypervisor": "xen",
                    "NetworkInterfaces": [
                        {
                            "Association": {
                                "IpOwnerId": "amazon",
                                "PublicDnsName": "ec2-13-220-238-237.compute-1.amazonaws.com",
                                "PublicIp": "13.220.238.237"
                            },
                            "Attachment": {
                                "AttachTime": "2026-07-22T14:51:01+00:00",
                                "AttachmentId": "eni-attach-08b093d8be5e3b4cc",
                                "DeleteOnTermination": true,
                                "DeviceIndex": 0,
                                "Status": "attached",
                                "NetworkCardIndex": 0
                            },
                            "Description": "",
                            "Groups": [
                                {
                                    "GroupId": "sg-06fff8f8c506c370f",
                                    "GroupName": "infrarevive-k8s-sg"
                                }
                            ],
                            "Ipv6Addresses": [],
                            "MacAddress": "02:0c:81:dd:d3:81",
                            "NetworkInterfaceId": "eni-00cd0979ef06fa48a",
                            "OwnerId": "916923735515",
                            "PrivateDnsName": "ip-172-20-5-148.ec2.internal",
                            "PrivateIpAddress": "172.20.5.148",
                            "PrivateIpAddresses": [
                                {
                                    "Association": {
                                        "IpOwnerId": "amazon",
                                        "PublicDnsName": "ec2-13-220-238-237.compute-1.amazonaws.com",
                                        "PublicIp": "13.220.238.237"
                                    },
                                    "Primary": true,
                                    "PrivateDnsName": "ip-172-20-5-148.ec2.internal",
                                    "PrivateIpAddress": "172.20.5.148"
                                }
                            ],
                            "SourceDestCheck": true,
                            "Status": "in-use",
                            "SubnetId": "subnet-0dfadd8f816e467d6",
                            "VpcId": "vpc-09c8853c8fae1a17a",
                            "InterfaceType": "interface",
                            "Operator": {
                                "Managed": false
                            }
                        }
                    ],
                    "RootDeviceName": "/dev/xvda",
                    "RootDeviceType": "ebs",
                    "SecurityGroups": [
                        {
                            "GroupId": "sg-06fff8f8c506c370f",
                            "GroupName": "infrarevive-k8s-sg"
                        }
                    ],
                    "SourceDestCheck": true,
                    "Tags": [
                        {
                            "Key": "Name",
                            "Value": "infrarevive-worker-1"
                        }
                    ],
                    "VirtualizationType": "hvm",
                    "CpuOptions": {
                        "CoreCount": 1,
                        "ThreadsPerCore": 2
                    },
                    "CapacityReservationSpecification": {
                        "CapacityReservationPreference": "open"
                    },
                    "HibernationOptions": {
                        "Configured": false
                    },
                    "MetadataOptions": {
                        "State": "applied",
                        "HttpTokens": "optional",
                        "HttpPutResponseHopLimit": 1,
                        "HttpEndpoint": "enabled",
                        "HttpProtocolIpv6": "disabled",
                        "InstanceMetadataTags": "disabled"
                    },
                    "EnclaveOptions": {
                        "Enabled": false
                    },
                    "PlatformDetails": "Linux/UNIX",
                    "UsageOperation": "RunInstances",
                    "UsageOperationUpdateTime": "2026-07-22T14:51:01+00:00",
                    "PrivateDnsNameOptions": {
                        "HostnameType": "ip-name",
                        "EnableResourceNameDnsARecord": false,
                        "EnableResourceNameDnsAAAARecord": false
                    },
                    "MaintenanceOptions": {
                        "AutoRecovery": "default",
                        "RebootMigration": "default"
                    },
                    "CurrentInstanceBootMode": "legacy-bios",
                    "NetworkPerformanceOptions": {
                        "BandwidthWeighting": "default"
                    },
                    "Operator": {
                        "Managed": false,
                        "HiddenByDefault": false
                    },
                    "SecondaryInterfaces": [],
                    "InstanceId": "i-065684521f3d5420c",
                    "ImageId": "ami-0c02fb55956c7d316",
                    "State": {
                        "Code": 16,
                        "Name": "running"
                    },
                    "PrivateDnsName": "ip-172-20-5-148.ec2.internal",
                    "PublicDnsName": "ec2-13-220-238-237.compute-1.amazonaws.com",
                    "StateTransitionReason": "",
                    "KeyName": "infrarevive-key",
                    "AmiLaunchIndex": 0,
                    "ProductCodes": [],
                    "InstanceType": "t3.micro",
                    "LaunchTime": "2026-07-23T08:47:50+00:00",
                    "Placement": {
                        "AvailabilityZoneId": "use1-az1",
                        "GroupName": "",
                        "Tenancy": "default",
                        "AvailabilityZone": "us-east-1a"
                    },
                    "Monitoring": {
                        "State": "disabled"
                    },
                    "SubnetId": "subnet-0dfadd8f816e467d6",
                    "VpcId": "vpc-09c8853c8fae1a17a",
                    "PrivateIpAddress": "172.20.5.148",
                    "PublicIpAddress": "13.220.238.237"
                }
            ]
        }
    ]
}
