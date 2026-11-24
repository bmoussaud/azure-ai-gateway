param amount int
param emails array
param start string

resource budget 'Microsoft.Consumption/budgets@2024-08-01' = {
  name: 'ai-gateway-demo-alert'
  properties: {
    category: 'Cost'
    amount: amount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: start
      endDate: dateTimeAdd(start, 'P1Y')
    }
    notifications: {
      actual: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 80
        thresholdType: 'Actual'
        contactEmails: emails
      }
    }
  }
}
