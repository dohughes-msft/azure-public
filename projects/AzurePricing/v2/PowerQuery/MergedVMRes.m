let
    Source = OnDemand,
    #"Filtered on Primary Meter and VMs" = Table.SelectRows(Source, each ([Is Primary Meter Region] = true) and ([Service Name] = "Virtual Machines")),
    #"Join with RI1Y" = Table.NestedJoin(
        #"Filtered on Primary Meter and VMs",
        {"Meter ID", "ARM Region Name"},
        #"Reservation - RI1Y - VM",
        {"Meter ID", "ARM Region Name"},
        "Price RI1Y",
        JoinKind.Inner
    ),
    #"Expanded Price RI1Y" = Table.ExpandTableColumn(#"Join with RI1Y", "Price RI1Y", {"Price RI1Y"}, {"Price RI1Y"}),
    #"Join with RI3Y" = Table.NestedJoin(
        #"Expanded Price RI1Y",
        {"Meter ID", "ARM Region Name"},
        #"Reservation - RI3Y - VM",
        {"Meter ID", "ARM Region Name"},
        "Price RI3Y",
        JoinKind.LeftOuter
    ),
    #"Expanded Price RI3Y" = Table.ExpandTableColumn(#"Join with RI3Y", "Price RI3Y", {"Price RI3Y"}, {"Price RI3Y"})
in
    #"Expanded Price RI3Y"