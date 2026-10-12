let
    Source = #"Pricing - Raw",
    #"Filtered on Term and VMs" = Table.SelectRows(Source, each ([Is Primary Meter Region] = true) and ([Reservation Term] = "1 Year") and ([Service Name] = "Virtual Machines")),
    #"Added Price RI1Y" = Table.AddColumn(#"Filtered on Term and VMs", "Price RI1Y", each [Unit Price]/(365*24)),
    #"Removed Other Columns" = Table.SelectColumns(#"Added Price RI1Y",{"ARM Region Name", "Meter ID", "Price RI1Y"}),
    #"Changed Type" = Table.TransformColumnTypes(#"Removed Other Columns",{{"ARM Region Name", type text}, {"Meter ID", type text}, {"Price RI1Y", type number}})
in
    #"Changed Type"