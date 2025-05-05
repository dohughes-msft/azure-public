# VM Modernisation via Azure Policy
## Introduction

Azure is evergreen, with newer and better virtual machine families being released regularly. Most of the time, pricing of these new SKUs is close or equivalent to older families, meaning there is almost always a net benefit, in terms of cost versus performance, in upgrading and using the latest machine types.

Azure customers may nevertheless find themselves with a mix of old and new SKUs, particularly in cases where workload owners have autonomy in choosing compute families and may not realise the impact of choosing older models. In the long run, Microsoft will eventually deprecate older families and thus customers may be forced to change SKUs at inopportune moments.

This mini-project explores creating an Azure policy to audit or even prevent teams from selecting SKUs that are deemed to have a better successor.

## How it works
1. We use a PowerShell script called [`GetVMFamilies.ps1`](GetVMFamilies.ps1) to get the current list of VM families from Azure
2. We use a macro-enabled Excel document [`VmModernisation.xlsm`](VmModernisation.xlsm) to sort the list and identify successor families where applicable
3. In the same document, we decide how strict or lenient we want to be in disallowing the use of older families. Some decisions to make here are:
   * do I forbid all families and only allow certain ones, i.e. whitelisting, or do I allow all families and only forbid certain ones, i.e. blacklisting?
   * how many generations back should I go - for example, allowing the current generation only, or allowing the current + previous X generations?
4. We export the disallowed list of SKUs (if blacklisting, which is the preferred method) to a JSON file for further processing into Azure policy
5. Finally, we use [PowerShell](powershell) or [Terraform](terraform) to create the Azure policy definition and assign it to a scope