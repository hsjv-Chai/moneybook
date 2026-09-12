import Foundation

/// 按关键词把微信账单的商户/商品信息映射到记账分类。
///
/// 微信账单本身不带分类，这里只用明确的行业关键词做保守匹配，匹配不到就交给用户设置的默认分类。
enum BillCategorizer {
    struct Rule {
        let categoryName: String
        let keywords: [String]
    }

    static let expenseRules: [Rule] = [
        Rule(categoryName: "餐饮", keywords: [
            "餐饮", "饭店", "餐厅", "外卖", "美团", "饿了么", "快餐", "小吃", "美食",
            "咖啡", "奶茶", "茶饮", "星巴克", "麦当劳", "肯德基", "汉堡", "烧烤", "火锅",
            "面馆", "早餐", "水果", "食堂", "蛋糕", "面包", "甜品", "点心", "食品",
            "喜茶", "瑞幸", "蜜雪", "库迪", "华莱士", "汉堡王", "餐", "茶",
            "coffee", "cafe", "tea", "luckin", "bakery", "cake",
        ]),
        Rule(categoryName: "交通", keywords: [
            "出行", "打车", "滴滴", "出租车", "网约车", "地铁", "公交", "公共交通",
            "加油", "停车", "高速", "etc", "ETC", "火车", "高铁", "机票", "航空",
            "单车", "摩拜", "哈啰", "青桔", "高德", "12306", "铁路", "机场",
        ]),
        Rule(categoryName: "购物", keywords: [
            "购物", "超市", "便利店", "京东", "淘宝", "天猫", "拼多多", "唯品会",
            "商场", "百货", "服饰", "数码", "家电", "免税", "山姆", "盒马", "永辉",
            "商城", "旗舰店", "优衣库", "名创优品", "宜家", "无印良品", "电器",
            "蔬果", "生鲜", "菜市场", "购", "apple",
        ]),
        Rule(categoryName: "居住", keywords: [
            "房租", "水费", "电费", "燃气", "物业", "宽带", "供暖", "家政", "保洁", "租赁",
            "公寓", "宿舍", "浴室", "热水", "水电", "取暖",
        ]),
        Rule(categoryName: "娱乐", keywords: [
            "电影", "影城", "游戏", "娱乐", "视频", "音乐", "会员", "KTV", "演出",
            "门票", "旅游", "景区", "酒店", "民宿",
            "旅行", "携程", "去哪儿", "飞猪", "途家", "度假",
        ]),
        Rule(categoryName: "医疗", keywords: [
            "医院", "药房", "药店", "医疗", "诊所", "体检", "挂号", "口腔", "眼科",
        ]),
        Rule(categoryName: "学习", keywords: [
            "书店", "图书", "教育", "培训", "课程", "学费", "文具", "考试",
        ]),
        Rule(categoryName: "通讯", keywords: [
            "话费", "流量", "通信", "移动", "联通", "电信", "手机充值",
        ]),
    ]

    static let incomeRules: [Rule] = [
        Rule(categoryName: "工资", keywords: ["工资", "薪资", "薪酬", "代发", "劳务"]),
        Rule(categoryName: "奖金", keywords: ["奖金", "年终", "红包", "奖励", "绩效"]),
        Rule(categoryName: "理财收益", keywords: ["收益", "利息", "分红", "理财", "基金", "零钱通"]),
        Rule(categoryName: "报销", keywords: ["报销", "补贴", "退款", "返现"]),
    ]

    /// 返回建议的分类名；没有命中任何规则时返回 nil。
    static func suggestedCategoryName(for row: BillRow, direction: BillDirection) -> String? {
        let haystack = [
            row.transactionType,
            row.counterparty,
            row.product,
            row.remark,
        ]
        .joined(separator: " ")
        .lowercased()
        guard !haystack.isEmpty else { return nil }

        let rules = direction == .income ? incomeRules : expenseRules
        for rule in rules {
            for keyword in rule.keywords where haystack.contains(keyword.lowercased()) {
                return rule.categoryName
            }
        }
        return nil
    }

    /// 在已有分类中找出匹配项，找不到时返回 nil。
    static func suggestedCategory(
        for row: BillRow,
        direction: BillDirection,
        categories: [EntryCategory]
    ) -> EntryCategory? {
        guard let name = suggestedCategoryName(for: row, direction: direction) else { return nil }
        return categories.first { $0.name == name }
    }
}
