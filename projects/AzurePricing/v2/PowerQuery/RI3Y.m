let
    Source = #"Pricing - Raw",
    #"Filtered on Term and VMs" = Table.SelectRows(Source, each ([Is Primary Meter Region] = true) and ([Reservation Term] = "3 Years") and ([Service Name] = "Virtual Machines")),
    #"Added Price RI3Y" = Table.AddColumn(#"Filtered on Term and VMs", "Price RI3Y", each [Unit Price]/(365*24*3)),
    #"Removed Other Columns" = Table.SelectColumns(#"Added Price RI3Y",{"ARM Region Name", "Meter ID", "Price RI3Y"}),
    #"Changed Type" = Table.TransformColumnTypes(#"Removed Other Columns",{{"ARM Region Name", type text}, {"Meter ID", type text}, {"Price RI3Y", type number}})
in
    #"Changed Type"