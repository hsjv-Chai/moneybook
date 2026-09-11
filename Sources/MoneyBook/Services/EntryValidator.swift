import Foundation

enum EntryValidationError: LocalizedError, Equatable {
    case amountNotPositive
    case missingAccount
    case missingCategory
    case sameTransferAccount
    case missingTransferDestination

    var errorDescription: String? {
        switch self {
        case .amountNotPositive: "请输入大于 0 的金额。"
        case .missingAccount: "请选择账户。"
        case .missingCategory: "请选择分类。"
        case .sameTransferAccount: "转出账户与转入账户不能相同。"
        case .missingTransferDestination: "请选择转入账户。"
        }
    }
}

/// 流水录入校验规则。
@MainActor
enum EntryValidator {
    static func validate(
        kind: EntryKind,
        amount: Decimal,
        category: EntryCategory?,
        account: Account?,
        toAccount: Account? = nil
    ) throws {
        guard amount > 0 else { throw EntryValidationError.amountNotPositive }

        switch kind {
        case .expense, .income:
            guard account != nil else { throw EntryValidationError.missingAccount }
            guard category != nil else { throw EntryValidationError.missingCategory }
        case .transfer:
            guard let account else { throw EntryValidationError.missingAccount }
            guard let toAccount else { throw EntryValidationError.missingTransferDestination }
            guard account.uuid != toAccount.uuid else { throw EntryValidationError.sameTransferAccount }
        }
    }
}
