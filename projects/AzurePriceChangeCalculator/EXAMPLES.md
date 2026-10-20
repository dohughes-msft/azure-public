# Price Increase Examples by Pricing Model

Consumption in Azure uses one of four pricing models:
* OnDemand, also known as Pay-as-you-go or PAYG
* Reservation
* SavingsPlan
* Spot, used for virtual machines only

Reservation and Savings Plans you have to actively purchase in order to use. Likewise for Spot, you have to actively choose this option when configuring your VM or scale set. Everything else uses the OnDemand pricing model.

Depending on which pricing model you are using, the price increases are going to have different effects. To illustrate, I use the simple example of a virtual machine that typically costs $100 per hour to run PAYG (OnDemand), that is getting a 25% price increase on February 1st.

The example is illustrative. Actual Azure prices, discounts, reservation terms, savings plan coverage, and Spot prices vary by resource, region, agreement, and time.

## Summary

| Pricing Model | Price / Discount |
|---|---|
| OnDemand price | $100 per hour |
| Reservation discount | 50% |
| Savings plan discount | 40% |
| Spot price during the last month | $20 per hour |

## 1. OnDemand (PAYG)

```text
OnDemand price prior to increase: $100 per hour
OnDemand price increase: 25%
OnDemand price after increase: $100 + $25 = $125 per hour
```

**Result:** The resource costs **$125 per hour**, an increase of **$25 per hour** or **25%**.

## 2. Spot

Spot pricing varies depending on several factors. It can be as low as 10% of the PAYG price but never higher than the PAYG price. Let's say that during the past month, the spot price has been $20 per hour, i.e. 80% discount to the PAYG price.

```text
OnDemand price prior to increase: $100 per hour
Spot discount: 80% during the past month
Spot price prior to increase: $100 x 0.2 = $20 per hour

OnDemand price increase: 25%

OnDemand price after increase = $125 per hour
Spot discount: Let's say the discount remains at 80%
Spot price after increase: $125 x 0.2 = $25 per hour
```

**Result:** In this simplified example, the price has increased from $20 to $25 per hour, an increase of **25%**.

This seems pretty obvious, but the point to understand is that the spot discount can vary from month to month, so the increase is likely to be close to but not exactly 25%.

## 3. Reservation

When you purchase a reservation you are guaranteed to keep the price at purchase for the lifetime of the reservation.

Let's say our resource is covered by a reservation that expires on July 1st 2027.

```text
OnDemand price prior to increase: $100 per hour
Reservation discount: 50%
Reservation price prior to increase: $100 x 0.5 = $50 per hour

OnDemand price increase: 25%

OnDemand price after increase = $125 per hour
Reservation price increase on February 1st 2027 = $0
```

Once the reservation expires on July 1st, we have two options:

### If the reservation expires on July 1st and is not renewed:

```text
Old reservation price = $50 per hour
New PAYG price = $125 per hour (reference only)
```

**Result:** The resource costs **$125 per hour**, an increase of **$75 per hour** or **150%**.

### If the reservation expires on July 1st and **is** renewed:

```text
Old reservation price: $50 per hour
New reservation price = $125 x 50% = $62.50 per hour
```

**Result:** The resource costs **$62.50 per hour**, an increase of **$12.50 per hour** or **25%**.

To summarize, reservations can delay the effect of the price increase until renewal date, but not longer.

## 4. Savings plan

Savings plan is perhaps the most complex case. When prices increase, your existing savings plan commitment covers less consumption than before. The overage becomes PAYG spend, which will cause the total price to go up more than 25%.

```text
OnDemand price prior to increase: $100 per hour
Savings plan discount: 40%
Savings plan price prior to increase: $100 x 0.6 = $60 per hour, covering 100% of the resource cost

OnDemand price after increase: $125 per hour
```

Here's where we have to stop and think. Your savings plan commitment of $60 per hour is still in place. At 40% discount, it is covering $100 of consumption just like it did before. But the resource price has increased so the savings plan does not cover all of it.

```text
OnDemand price after increase: $125 per hour
Consumption covered by savings plan: $100 per hour ($60 of savings plan covers $100 of consumption)
Overage: $25 per hour, charged as OnDemand
Resource price after increase: $60 + $25 = $85 per hour
```

**Result:** The resource costs $60 + $25 = **$85 per hour**, an increase of **$25 per hour** or **41.6%**.

You can contain the price increase by purchasing an extra savings plan to cover it:

```text
Extra savings plan purchased: $15 per hour covering $25 per hour of OnDemand consumption
Resource price after increase: $60 + $15 = $75 per hour
```

Resource price after purchase of extra savings plan: $75 per hour, containing the increase to **25%**.
