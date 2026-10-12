import Foundation

/// 搜索里的一个画面概念，例如「猫」→ Vision 的 cat。
struct PhotoConcept: Hashable {
    /// 用户写的词，用在标签上：「画面：猫」。
    let word: String
    /// 对应的 Vision 分类标识（VNClassifyImageRequest 的 identifier）。
    let labels: [String]
}

/// 中文 / 英文词 → Vision 图像分类标识。只依赖 Foundation，单元测试也会编译它。
///
/// 标识按「词」匹配：`cat` 匹配 `cat`，也匹配 `xxx_cat`、`cat_xxx` 这类组合标识，
/// 这样即使某个标识在 Vision 的分类表里叫法稍有不同，也大多能对上。
enum PhotoConcepts {
    /// (同义词, Vision 标识)
    static let table: [([String], [String])] = [
        (["猫", "猫咪", "小猫", "cat", "cats"], ["cat", "kitten"]),
        (["狗", "狗狗", "小狗", "dog", "dogs"], ["dog", "puppy"]),
        (["鸟", "小鸟", "bird", "birds"], ["bird"]),
        (["鱼", "fish"], ["fish"]),
        (["马", "horse"], ["horse"]),
        (["动物", "宠物", "animal", "animals", "pet"], ["animal", "mammal", "cat", "dog", "bird", "pet"]),
        (["海边", "海滩", "沙滩", "beach"], ["beach", "shore", "seashore"]),
        (["大海", "海洋", "海水", "ocean", "sea"], ["ocean", "sea", "seascape", "beach", "shore"]),
        (["山", "山脉", "爬山", "mountain", "mountains"], ["mountain", "hill", "peak"]),
        (["雪", "雪景", "下雪", "snow"], ["snow", "snowing"]),
        (["食物", "美食", "饭", "吃的", "food"], ["food", "meal", "dish", "dessert", "fruit"]),
        (["蛋糕", "cake"], ["cake", "birthday_cake"]),
        (["甜点", "甜品", "dessert"], ["dessert", "cake", "ice_cream", "pastry"]),
        (["水果", "fruit"], ["fruit"]),
        (["披萨", "比萨", "pizza"], ["pizza"]),
        (["寿司", "sushi"], ["sushi"]),
        (["面包", "bread"], ["bread"]),
        (["咖啡", "coffee"], ["coffee"]),
        (["饮料", "drink", "drinks"], ["drink", "beverage", "coffee", "juice"]),
        (["花", "鲜花", "花朵", "flower", "flowers"], ["flower", "blossom", "bouquet"]),
        (["树", "树木", "tree", "trees"], ["tree"]),
        (["森林", "树林", "forest"], ["forest", "woodland"]),
        (["草地", "草坪", "grass"], ["grass", "lawn"]),
        (["植物", "plant", "plants"], ["plant", "houseplant", "foliage"]),
        (["车", "汽车", "轿车", "car", "cars"], ["car", "automobile", "vehicle"]),
        (["自行车", "单车", "bicycle", "bike"], ["bicycle", "bike"]),
        (["摩托车", "motorcycle"], ["motorcycle"]),
        (["火车", "train"], ["train", "railway"]),
        (["飞机", "airplane", "plane"], ["airplane", "aircraft", "airliner"]),
        (["船", "boat"], ["boat", "ship", "watercraft"]),
        (["文件", "文档", "document", "documents"], ["document", "paper", "text"]),
        (["收据", "发票", "小票", "receipt", "invoice"], ["receipt", "invoice"]),
        (["截图", "screenshot"], ["screenshot"]),
        (["书", "书本", "book", "books"], ["book"]),
        (["电脑", "笔记本电脑", "computer", "laptop"], ["computer", "laptop"]),
        (["手机", "phone"], ["phone", "cellphone", "smartphone"]),
        (["天空", "sky"], ["sky"]),
        (["云", "云朵", "cloud", "clouds"], ["cloud", "cloudy"]),
        (["夜景", "夜晚", "夜空", "night"], ["night_sky", "night", "nightlife"]),
        (["星空", "星星", "stars"], ["night_sky", "star", "milky_way"]),
        (["日落", "日出", "夕阳", "晚霞", "sunset", "sunrise"], ["sunset", "sunrise", "sunset_sunrise"]),
        (["彩虹", "rainbow"], ["rainbow"]),
        (["烟花", "fireworks"], ["fireworks"]),
        (["湖", "湖泊", "lake"], ["lake"]),
        (["河", "河流", "river"], ["river"]),
        (["瀑布", "waterfall"], ["waterfall"]),
        (["沙漠", "desert"], ["desert"]),
        (["城市", "街景", "city", "street"], ["city", "cityscape", "street", "skyline"]),
        (["建筑", "大楼", "building", "buildings"], ["building", "architecture", "skyscraper"]),
        (["桥", "bridge"], ["bridge"]),
        (["婴儿", "宝宝", "baby"], ["baby", "infant", "toddler"]),
        (["孩子", "小孩", "儿童", "kid", "kids", "child"], ["child", "baby", "toddler"]),
        (["人", "人物", "人像", "people", "person"], ["people", "person", "adult", "child", "portrait", "selfie"]),
        (["自拍", "selfie"], ["selfie", "portrait"]),
        (["合影", "合照", "人群", "crowd"], ["crowd", "people", "group"]),
        (["婚礼", "wedding"], ["wedding", "bride"]),
        (["玩具", "toy", "toys"], ["toy", "teddy_bear"]),
        (["衣服", "服装", "clothing", "clothes"], ["clothing", "dress", "shirt"]),
        (["鞋", "鞋子", "shoes"], ["shoes", "footwear", "sneaker"]),
        (["运动", "sport", "sports"], ["sport", "ball", "stadium"]),
        (["圣诞", "christmas"], ["christmas", "christmas_tree"]),
    ]

    /// 写在「画面」概念前后、不影响含义的字。
    private static let fillers = [
        "的照片", "的图片", "的相片", "的图", "照片", "图片", "相片", "画面", "里有", "有", "的", "张",
        "photos", "photo", "pictures", "picture", "pics", "images", "image", "of", "with",
    ]

    /// 按长度从长到短排好的 (词, 概念)，长词优先（「海边」先于「海」）。
    private static let entries: [(String, PhotoConcept)] = {
        var list: [(String, PhotoConcept)] = []
        for (words, labels) in table {
            for word in words {
                list.append((word, PhotoConcept(word: word, labels: labels)))
            }
        }
        return list.sorted { $0.0.count > $1.0.count }
    }()

    /// 从搜索文字里找出画面概念。
    ///
    /// 两个字以上的中文词只要出现就算（「海边的照片」「去年的猫咪」）；
    /// 单个字（猫、山、人、花……）和英文词必须几乎就是整个搜索词，避免「上海」「个人简历」误判。
    static func match(_ text: String) -> PhotoConcept? {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lowered.isEmpty else { return nil }
        var core = lowered
        for filler in fillers {
            core = core.replacingOccurrences(of: filler, with: " ")
        }
        let tokens = core.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        // 整个词（或其中一个词）恰好是概念。
        for (word, concept) in entries where tokens.contains(word) {
            return concept
        }
        // 两个字以上的中文词：包含即可。
        for (word, concept) in entries where word.count >= 2 && !isASCII(word) && lowered.contains(word) {
            return concept
        }
        return nil
    }

    /// 一个分类标识是否符合概念里的某个标识（按「_」分词匹配）。
    static func label(_ identifier: String, matches term: String) -> Bool {
        let id = "_" + identifier.lowercased() + "_"
        return id.contains("_" + term.lowercased() + "_")
    }

    static func matches(labels identifiers: [String], concept: PhotoConcept) -> Bool {
        identifiers.contains { id in concept.labels.contains { label(id, matches: $0) } }
    }

    private static func isASCII(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy(\.isASCII)
    }
}
