import Foundation

public enum StorePrice {
    public static func monthly(cents: Int) -> String {
        "\(dollars(cents: cents))/month"
    }

    public static func dollars(cents: Int) -> String {
        let wholeDollars = cents / 100
        let remainingCents = cents % 100
        return remainingCents == 0 ? "$\(wholeDollars)" : String(format: "$%d.%02d", wholeDollars, remainingCents)
    }
}
