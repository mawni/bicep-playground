@description('String used as a base for naming resources. Must be 3-61 characters in length and globally unique across Azure. A hash is prepended to this string for some resources, and resource-specific information is appended.')
@minLength(3)
@maxLength(61)
param vmssName string

@description('Size of VMs in the VM Scale Set.')
param vmSku string = 'Standard_D2s_v3'

@description('The Windows version for the VM. This will pick a fully patched image of this given Windows version. Allowed values: 2008-R2-SP1, 2012-Datacenter, 2012-R2-Datacenter & 2016-Datacenter, 2019-Datacenter.')
@allowed([
  '2019-DataCenter-GenSecond'
  '2016-DataCenter-GenSecond'
  '2022-datacenter-azure-edition'
])
param windowsOSVersion string = '2022-datacenter-azure-edition'

@description('Security Type of the Virtual Machine.')
@allowed([
  'Standard'
  'TrustedLaunch'
])
param securityType string = 'TrustedLaunch'

@description('Number of VM instances (100 or less).')
@minValue(1)
@maxValue(100)
param instanceCount int = 3

@description('When true this limits the scale set to a single placement group, of max size 100 virtual machines. NOTE: If singlePlacementGroup is true, it may be modified to false. However, if singlePlacementGroup is false, it may not be modified to true.')
param singlePlacementGroup bool = true

@description('Admin username on all VMs.')
param adminUsername string = 'vmssadmin'

@description('Admin password on all VMs.')
@secure()
param adminPassword string

@description('Location for all resources.')
param location string = resourceGroup().location

@description('Fault Domain count for each placement group.')
param platformFaultDomainCount int = 1

var vmScaleSetName = toLower(substring('vmssName${uniqueString(resourceGroup().id)}', 0, 9))
// var longvmScaleSet = toLower(vmssName)
var addressPrefix = '10.0.0.0/16'
var subnetPrefix = '10.0.0.0/24'
var vNetName = '${vmScaleSetName}vnet'
// var publicIPAddressName = '${vmScaleSetName}pip'
var subnetName = '${vmScaleSetName}subnet'
var nicName = '${vmScaleSetName}nic'
var ipConfigName = '${vmScaleSetName}ipconfig'
var osType = {
  publisher: 'MicrosoftWindowsServer'
  offer: 'WindowsServer'
  sku: windowsOSVersion
  version: 'latest'
}
var securityProfileJson = {
  uefiSettings: {
    secureBootEnabled: true
    vTpmEnabled: true
  }
  securityType: securityType
}
var imageReference = osType

// Network Security Group
resource nsg 'Microsoft.Network/networkSecurityGroups@2021-02-01' = {
  name: '${vmssName}nsg'
  location: location
  properties: {
    securityRules: [
      // Rule that allows outbound traffic on port 443. For future outbound access to azure automation and log analytics
      {
        name: 'AllowHTTPSOutbound'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'AzureCloud'
          access: 'Allow'
          priority: 100
          direction: 'Outbound'
        }
      }
    ]
  }
}

resource vmScaleSet 'Microsoft.Compute/virtualMachineScaleSets@2023-09-01' = {
  name: vmScaleSetName
  location: location
  sku: {
    name: vmSku
    tier: 'Standard'
    capacity: instanceCount
  }
  properties: {
    overprovision: true
    upgradePolicy: {
      mode: 'Automatic'
    }
    singlePlacementGroup: singlePlacementGroup
    platformFaultDomainCount: platformFaultDomainCount
    virtualMachineProfile: {
      storageProfile: {
        osDisk: {
          caching: 'ReadWrite'
          createOption: 'FromImage'
        }
        imageReference: imageReference
      }
      osProfile: {
        computerNamePrefix: vmScaleSetName
        adminUsername: adminUsername
        adminPassword: adminPassword
      }
      securityProfile: ((securityType == 'TrustedLaunch') ? securityProfileJson : null)
      networkProfile: {
        networkInterfaceConfigurations: [
          {
            name: nicName
            properties: {
              primary: true
              // below we assocate the security group rule created in a separate resource to this VMSS network profile
              networkSecurityGroup: {
                  id: nsg.id
              }
              ipConfigurations: [
                {
                  name: ipConfigName
                  properties: {
                    subnet: {
                      id: vNet.properties.subnets[0].id
                    }
                  }
                }
              ]
            }
          }
        ]
      }
      extensionProfile: {
        extensions: []
      }
    }
  }
}

// resource publicIPAddress 'Microsoft.Network/publicIPAddresses@2023-04-01' = {
//   name: publicIPAddressName
//   location: location
//   properties: {
//     publicIPAllocationMethod: 'Static'
//     dnsSettings: {
//       domainNameLabel: longvmScaleSet
//     }
//   }
// }

resource vNet 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: vNetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefix
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetPrefix
        }
      }
    ]
  }
}

// autoscale setup for the VMSS. Works on CPU utilisation. In future, may extend to include memory triggers as well
resource autoscalehost 'Microsoft.Insights/autoscalesettings@2022-10-01' = {
  name: 'autoscalehost'
  location: location
  properties: {
    name: 'autoscalehost'
    targetResourceUri: vmScaleSet.id
    enabled: true
    profiles: [
      {
        name: 'Profile1'
        capacity: {
          minimum: '1'
          maximum: '10'
          default: '1'
        }
        rules: [
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricResourceUri: vmScaleSet.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT5M'
              timeAggregation: 'Average'
              operator: 'GreaterThan'
              threshold: 50
            }
            scaleAction: {
              direction: 'Increase'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT5M'
            }
          }
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricResourceUri: vmScaleSet.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT5M'
              timeAggregation: 'Average'
              operator: 'LessThan'
              threshold: 30
            }
            scaleAction: {
              direction: 'Decrease'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT5M'
            }
          }
        ]
      }
    ]
  }
}

// output applicationUrl string = uri('http://${publicIPAddress.properties.dnsSettings.fqdn}', '/MyApp')
