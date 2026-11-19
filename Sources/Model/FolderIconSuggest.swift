import Foundation

/// 「文件夹换装」的智能推荐：按文件夹名字推荐几款现成的样式（自带主题图标，或者颜色 + SF 符号叠加层）。
/// 全在本机查一张关键词表，不联网；中文、英文、拼音全拼 / 首字母都认，不分大小写、空格、标点、数字、全角半角、繁简。
/// 这个文件只用 Foundation（加 FolderIconStyle.swift 里的样式和主题目录），单元测试直接编译它。
struct FolderIconSuggestion: Hashable, Identifiable {
    /// 关键词表里的主题（如 screenshot、design）。
    let topic: String
    let style: FolderIconStyle
    /// 名字里认出来的关键词（截图、screenshot、jietu……）。
    let keyword: String
    /// 给人看的理由：名字里有「截图」 / 在「截图」里。
    let reason: String
    let score: Int

    var id: FolderIconStyle { style }
}

enum FolderIconSuggest {
    /// 设置 › 外观：「新建文件夹时推荐图标」（默认开）。
    static let promptKey = "folderIconSuggestOnNewFolder"
    /// 最多推荐几款。
    static let defaultLimit = 6

    struct Match: Equatable {
        let topic: String
        let keyword: String
        let score: Int
        /// 关键词在名字里出现的位置（同分时靠前的排前面）。
        let position: Int
    }

    struct Topic {
        let id: String
        let chinese: [String]
        let english: [String]
        let pinyin: [String]
        let initials: [String]
        let styles: [FolderIconStyle]

        var keywordCount: Int { chinese.count + english.count + pinyin.count + initials.count }
    }

    // MARK: 推荐

    /// 按名字推荐，最多 limit 款，排在前面的最贴切。几个主题都对得上时轮流各取一款（「客户-截图」两样都有）。
    /// 名字里认不出来时，再看上层文件夹的名字（「截图」里新建的「2026-11」也推荐截图图标），理由写「在「截图」里」。
    static func suggestions(for name: String, parentName: String? = nil, limit: Int = defaultLimit) -> [FolderIconSuggestion] {
        guard limit > 0 else { return [] }
        var found = matches(for: name).map { ($0, String(localized: "名字里有「\($0.keyword)」")) }
        if found.isEmpty, let parentName, !parentName.isEmpty {
            found = matches(for: parentName).map {
                (Match(topic: $0.topic, keyword: $0.keyword, score: $0.score / 2, position: $0.position),
                 String(localized: "在「\(parentName)」里"))
            }
        }
        guard !found.isEmpty else { return [] }
        let byID = Dictionary(topics.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [FolderIconSuggestion] = []
        var seen = Set<FolderIconStyle>()
        let rounds = found.compactMap { byID[$0.0.topic]?.styles.count }.max() ?? 0
        for round in 0..<rounds {
            for (match, reason) in found {
                guard let topic = byID[match.topic], round < topic.styles.count else { continue }
                let style = topic.styles[round]
                guard seen.insert(style).inserted else { continue }
                result.append(FolderIconSuggestion(topic: topic.id, style: style, keyword: match.keyword,
                                                   reason: reason, score: match.score))
                if result.count >= limit { return result }
            }
        }
        return result
    }

    /// 新建文件夹后的小提示用：最贴切的一款，没有返回 nil。
    static func best(for name: String) -> FolderIconSuggestion? {
        suggestions(for: name, limit: 1).first
    }

    /// 名字对得上哪些主题，按分数从高到低（同分按出现位置）。
    static func matches(for name: String) -> [Match] {
        let parts = normalize(name)
        guard !parts.compact.isEmpty else { return [] }
        var result: [Match] = []
        for topic in topics {
            var best: Match?
            func consider(_ keyword: String, _ hit: (score: Int, position: Int, whole: Bool)?) {
                guard let hit else { return }
                let score = hit.score + (hit.whole ? 30 : 0)
                if best == nil || score > best!.score || (score == best!.score && hit.position < best!.position) {
                    best = Match(topic: topic.id, keyword: keyword, score: score, position: hit.position)
                }
            }
            for keyword in topic.chinese { consider(keyword, matchChinese(keyword, parts)) }
            for keyword in topic.english { consider(keyword.replacingOccurrences(of: "_", with: " "), matchEnglish(keyword, parts)) }
            for keyword in topic.pinyin { consider(keyword, matchPinyin(keyword, parts)) }
            for keyword in topic.initials { consider(keyword, matchToken(keyword, parts, perLetter: 3)) }
            if let best { result.append(best) }
        }
        return result.sorted { $0.score != $1.score ? $0.score > $1.score : $0.position < $1.position }
    }

    // MARK: 名字整理

    struct Parts: Equatable {
        /// 英文 / 拼音单词（小写，驼峰拆开，数字和符号都当分隔）。
        let tokens: [String]
        /// 只留文字（汉字、字母），去掉空格、标点、数字。
        let compact: String
        /// 所有英文单词连在一起（「screen shots」→ screenshots）。
        let asciiCompact: String
    }

    /// 拾掇 / 访达新建文件夹的默认名字：不算进名字里（「包含项目的新建文件夹」不该推荐「项目」）。
    static let defaultNames = ["包含项目的新建文件夹", "未命名文件夹", "新建文件夹", "untitled folder", "new folder", "folder with items"]

    static func normalize(_ name: String) -> Parts {
        var text = name.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? name
        text = text.applyingTransform(StringTransform(rawValue: "Hant-Hans"), reverse: false) ?? text
        // 驼峰拆开：MyProjects → My Projects
        var split = ""
        var previous: Character?
        for character in text {
            if let previous, previous.isASCII, previous.isLowercase, character.isASCII, character.isUppercase {
                split.append(" ")
            }
            split.append(character)
            previous = character
        }
        var lower = split.lowercased()
        for stop in defaultNames { lower = lower.replacingOccurrences(of: stop, with: " ") }
        let tokens = lower.split(whereSeparator: { !($0.isASCII && $0.isLetter) }).map(String.init)
        let compact = String(lower.filter { $0.isLetter })
        return Parts(tokens: tokens, compact: compact, asciiCompact: tokens.joined())
    }

    private static func offset(of needle: String, in text: String) -> Int {
        guard let range = text.range(of: needle) else { return Int.max }
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    /// 中文关键词：整理后的名字里出现就算（「2026 设计素材 final」里有「设计」「素材」）。
    private static func matchChinese(_ keyword: String, _ parts: Parts) -> (score: Int, position: Int, whole: Bool)? {
        guard parts.compact.contains(keyword) else { return nil }
        return (10 * keyword.count, offset(of: keyword, in: parts.compact), parts.compact == keyword)
    }

    /// 英文关键词：短词要整词对上（可以带 s / es / ed / ing / er / ers），免得 network 里认出 work；
    /// 7 个字母以上或多个词的（screenshot、time machine）连在一起找，「Screen Shots」「myscreenshots」也认。
    private static func matchEnglish(_ keyword: String, _ parts: Parts) -> (score: Int, position: Int, whole: Bool)? {
        let joined = keyword.replacingOccurrences(of: "_", with: "")
        if keyword.contains("_") || joined.count >= 7 {
            guard parts.asciiCompact.contains(joined) else { return nil }
            let whole = parts.asciiCompact == joined || parts.asciiCompact == joined + "s" || parts.asciiCompact == joined + "es"
            return (4 * joined.count, offset(of: joined, in: parts.compact), whole)
        }
        let suffixes = ["", "s", "es", "ed", "ing", "er", "ers"]
        guard let token = parts.tokens.first(where: { token in suffixes.contains { token == joined + $0 } }) else { return nil }
        return (4 * joined.count, offset(of: token, in: parts.compact), parts.tokens.count == 1)
    }

    /// 拼音全拼：5 个字母以上的连在一起找（shejisucai），短的要整词对上（biji 不会在别的英文词里误认）。
    private static func matchPinyin(_ keyword: String, _ parts: Parts) -> (score: Int, position: Int, whole: Bool)? {
        if keyword.count >= 5 {
            guard parts.asciiCompact.contains(keyword) else { return nil }
            return (3 * keyword.count, offset(of: keyword, in: parts.compact), parts.asciiCompact == keyword)
        }
        return matchToken(keyword, parts, perLetter: 3)
    }

    /// 整词对上（拼音首字母 jt、sjsc 这种只认整词）。
    private static func matchToken(_ keyword: String, _ parts: Parts, perLetter: Int) -> (score: Int, position: Int, whole: Bool)? {
        guard parts.tokens.contains(keyword) else { return nil }
        return (perLetter * keyword.count, offset(of: keyword, in: parts.compact), parts.tokens.count == 1)
    }

    // MARK: 关键词表

    /// 颜色名 → 十六进制（和换装编辑器的调色板一样）。
    static let colors: [String: String] = [
        "coral": "F07363", "orange": "F5875C", "wheat": "EDBF6E", "pine": "70A382", "sky": "87B3EB",
        "lilac": "8F87ED", "pink": "ED8096", "graphite": "4F6969", "silver": "E3E3E8",
    ]

    /// 「s:符号名:颜色」或「t:分类/名字」（自带主题图标）。认不出来、主题不存在的返回 nil。
    static func style(from preset: String) -> FolderIconStyle? {
        let parts = preset.split(separator: ":").map(String.init)
        if parts.count == 3, parts[0] == "s", let hex = colors[parts[2]] {
            return FolderIconStyle(color: hex, overlay: .symbol(parts[1]))
        }
        if parts.count == 2, parts[0] == "t", FolderThemeCatalog.allThemes.contains(parts[1]) {
            return FolderIconStyle(color: "87B3EB", theme: parts[1])
        }
        return nil
    }

    static let topics: [Topic] = table.split(separator: "\n").compactMap { line -> Topic? in
        let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 6, !fields[0].isEmpty else { return nil }
        func words(_ text: String) -> [String] { text.split(separator: " ").map { String($0).lowercased() } }
        let styles = fields[5].split(separator: " ").compactMap { style(from: String($0)) }
        guard !styles.isEmpty else { return nil }
        return Topic(id: fields[0], chinese: words(fields[1]), english: words(fields[2]), pinyin: words(fields[3]),
                     initials: words(fields[4]), styles: styles)
    }

    static var keywordCount: Int { topics.reduce(0) { $0 + $1.keywordCount } }

    /// 一行一个主题：主题|中文|英文（多个词用 _ 连）|拼音全拼|拼音首字母|推荐样式（最贴切的在前）。
    /// 只写 App 里真有的主题图标（ThemeIcons/<分类>/<名字>.png）和 macOS 14 就有的 SF 符号，单元测试会检查。
    static let table = """
    screenshot|截图 截屏 屏幕截图 屏幕快照 快照 截取|screenshot snapshot screencap screencapture capture cleanshot snipaste shottr|jietu jieping kuaizhao|jt|s:camera.viewfinder:sky s:scissors:lilac s:photo.on.rectangle.angled:pine
    design|设计 设计稿 视觉 美工 插画 海报 原型 灵感 配色 平面 排版|design designs designer ui ux figma sketch psd photoshop ps xd mockup artwork art graphics illustration illustrator poster inspiration moodboard brand branding logo icons|sheji shijue chahua haibao linggan|sj sjg sjsc|s:paintpalette.fill:lilac s:pencil.and.ruler.fill:orange t:material/holographic
    assets|素材 素材库 资源 资产 图库 物料|assets asset resources resource stock materials|sucai ziyuan wuliao|sc sck sjsc|s:square.stack.3d.up.fill:orange s:photo.on.rectangle.angled:lilac s:shippingbox.fill:wheat
    photos|照片 相片 图片 相册 图像 摄影 拍照 写真|photos photo pictures picture pics pic images image img gallery photography camera dcim|zhaopian xiangpian tupian xiangce sheying|zp tp|s:photo.fill:sky s:camera.fill:coral s:photo.on.rectangle.angled:pink
    wallpaper|壁纸 桌布 屏保|wallpaper wallpapers backgrounds screensaver|bizhi||t:starry/galaxy t:starry/aurora s:photo.fill:lilac
    downloads|下载 下载的|downloads download dl|xiazai|xz|s:arrow.down.circle.fill:sky s:tray.and.arrow.down.fill:pine
    documents|文档 文稿 资料 文案 报告 稿件 公文 表格|documents document docs doc papers reports report writing word excel pdf spreadsheets|wendang wengao ziliao wenan baogao|wd|s:doc.text.fill:sky s:doc.richtext.fill:wheat s:doc.on.doc.fill:graphite
    notes|笔记 备忘 备忘录 随记 记录 日记 手账|notes note memo memos journal diary notebook|biji beiwang riji||s:note.text:wheat s:pencil:orange s:book.closed.fill:pine
    contract|合同 协议 签约 法务 授权书 条款|contract contracts agreement agreements legal nda terms|hetong xieyi fawu|ht|s:signature:graphite s:doc.text.fill:wheat s:checkmark.seal.fill:pine
    finance|财务 发票 报销 账单 收据 税务 个税 工资 预算 账本 记账 银行 理财 对账 付款 收款 开支|finance financial invoice invoices receipt receipts tax taxes bill bills billing budget bank salary payroll accounting expenses payment payments|caiwu fapiao baoxiao zhangdan shuiwu gongzi yusuan jizhang yinhang licai|cw fp bx|s:yensign.circle.fill:pine s:banknote.fill:wheat s:chart.pie.fill:sky
    videos|视频 影片 电影 录屏 短视频 剪辑 影视 片子 纪录片 动画|videos video movies movie films film footage clips clip recordings recording mp4 vlog animation|shipin yingpian dianying luping jianji|sp|s:film.fill:coral s:video.fill:graphite s:play.rectangle.fill:pink
    music|音乐 歌曲 歌单 伴奏 铃声 乐谱 唱歌 专辑|music songs song playlist playlists album albums mp3 beats karaoke|yinyue gequ gedan banzou lingsheng|yy|s:music.note:pink s:music.note.list:lilac s:guitars.fill:orange
    audio|音频 录音 播客 配音 音效 语音 有声书|audio podcast podcasts voice voices sound sounds sfx voiceover|yinpin luyin boke peiyin yinxiao yuyin||s:mic.fill:coral s:waveform:sky s:headphones:lilac
    projects|项目 工程 方案 提案 计划书 立项|projects project proposal proposals|xiangmu fangan|xm|s:briefcase.fill:sky s:checklist:pine s:hammer.fill:orange
    code|开发 代码 编程 程序 源码 仓库 脚本 前端 后端|code coding dev develop developer development src source repo repos repository github git gitlab xcode programming scripts frontend backend swift python|kaifa daima biancheng chengxu yuanma jiaoben|kf dm|s:chevron.left.forwardslash.chevron.right:graphite s:terminal.fill:pine t:apple/imac-g3
    backup|备份 存档 时光机 镜像|backup backups bak time_machine timemachine mirror|beifen cundang|bf|s:externaldrive.fill:graphite s:clock.arrow.circlepath:sky s:archivebox.fill:wheat
    clients|客户 甲方 顾客 客人 合作方 供应商 经销商 代理商 渠道 门店|clients client customers customer partners partner crm vendors vendor suppliers supplier dealers dealer|kehu jiafang gongyingshang jingxiaoshang|kh|s:person.2.fill:sky s:person.crop.circle.fill:orange s:briefcase.fill:graphite
    archive|归档 旧文件 老文件 以前 往期 过往 已完成 完结 历史 旧版|archive archives archived old history past done finished legacy|guidang wangqi lishi|gd|s:archivebox.fill:wheat s:tray.full.fill:silver s:shippingbox.fill:graphite
    desktop|桌面|desktop|zhuomian|zm|s:desktopcomputer:sky s:display:lilac t:apple/imac
    fonts|字体 字库 字形 字型|fonts font typeface typefaces typography ttf otf|ziti ziku|zt|s:textformat:graphite s:character.book.closed.fill:lilac s:pencil.and.ruler.fill:wheat
    work|工作 公司 办公 上班 业务 周报 日报 月报 会议 部门 同事|work office job jobs business company meetings meeting team|gongzuo gongsi bangong yewu zhoubao huiyi|gz|s:briefcase.fill:graphite s:building.2.fill:sky s:case.fill:orange
    study|学习 课程 课件 教程 作业 考试 论文 培训 学校 大学 考研 网课 讲义 复习 题库|study studies course courses class classes lecture lectures school homework exam exams learning learn tutorial tutorials thesis university college training|xuexi kecheng kejian jiaocheng zuoye kaoshi lunwen peixun xuexiao kaoyan wangke||s:graduationcap.fill:sky s:book.fill:orange s:books.vertical.fill:pine
    books|电子书 书籍 小说 阅读 图书 杂志 书单 读书|books book ebooks ebook kindle epub reading novels novel magazines magazine|dianzishu shuji xiaoshuo yuedu tushu zazhi dushu||s:books.vertical.fill:orange s:book.fill:wheat s:book.closed.fill:pine
    travel|旅行 旅游 出差 行程 机票 酒店 签证 度假 游记 出国 自驾 攻略|travel travels trip trips vacation holiday holidays journey flight flights visa passport hotel hotels|lvxing lvyou chuchai xingcheng jipiao jiudian qianzheng dujia gonglue|lx ly|s:airplane:sky s:suitcase.fill:orange t:planet/earth t:building/eiffel
    family|家庭 家人 家里 父母 爸妈 爸爸 妈妈 老婆 老公 婚礼 亲子 全家 家族 结婚|family parents parent mom dad wedding marriage|jiating jiaren fumu bama jiehun hunli||s:house.fill:orange s:figure.and.child.holdinghands:pink t:animal/plush-bear
    baby|宝宝 孩子 儿童 婴儿 儿子 女儿 小朋友 娃|baby babies kids kid children child|baobao haizi ertong erzi nver||s:teddybear.fill:pink s:stroller.fill:sky t:animal/plush-rabbit
    house|房子 装修 租房 房产 买房 家居 新家 房屋|house home rent apartment renovation interior|fangzi zhuangxiu zufang fangchan jiaju||s:house.fill:sky s:sofa.fill:wheat s:lamp.desk.fill:orange
    pets|宠物 萌宠 毛孩子|pets pet|chongwu mengchong||s:pawprint.fill:wheat t:animal/cat t:animal/dog
    cat|猫 猫咪 小猫 喵 橘猫 布偶|cat cats kitty kitten kittens|maomi xiaomao|mao|t:animal/cat t:animal/plush-cat s:cat.fill:wheat
    dog|狗 狗狗 小狗 柴犬 狗年 金毛|dog dogs puppy puppies doggy shiba corgi|gougou xiaogou chaiquan|gou|t:animal/dog t:animal/plush-shiba t:animal/plush-puppy s:dog.fill:wheat
    panda|熊猫 大熊猫 滚滚|panda pandas|xiongmao||t:animal/panda t:animal/plush-panda
    fox|狐狸 小狐狸|fox foxes|huli||t:animal/fox t:animal/plush-fox
    rabbit|兔子 小兔 兔兔 兔年 白兔|rabbit rabbits bunny|tuzi xiaotu||t:animal/rabbit t:animal/plush-rabbit s:hare.fill:pink
    bear|小熊 熊熊 泰迪熊 棕熊 狗熊 北极熊|bear bears teddy|xiaoxiong||t:animal/bear t:animal/plush-bear s:teddybear.fill:wheat
    ocean|海洋 大海 海边 潜水 金鱼 水族 珊瑚 海底 鱼|ocean sea beach diving fish aquarium coral reef underwater|haiyang dahai haibian qianshui||t:animal/coral-fish t:animal/jellyfish s:fish.fill:sky
    turtle|乌龟 海龟 小龟|turtle turtles tortoise|wugui haigui||t:animal/turtle s:tortoise.fill:pine
    octopus|章鱼 八爪鱼|octopus|zhangyu||t:animal/octopus
    jellyfish|水母|jellyfish|shuimu||t:animal/jellyfish
    elephant|大象 小象|elephant elephants|daxiang||t:animal/plush-elephant
    mouse|老鼠 鼠年 小鼠 仓鼠|mouse mice rat hamster|laoshu cangshu||t:animal/plush-mouse
    ox|牛年 小牛 奶牛 牛牛|ox cow cows cattle|niunian||t:animal/plush-ox
    tiger|老虎 虎年 小虎|tiger tigers|laohu hunian||t:animal/plush-tiger
    dragon|龙年 小龙|dragon dragons|longnian||t:animal/plush-dragon
    snake|蛇年 小蛇|snake snakes|shenian||t:animal/plush-snake
    horse|马年 小马 骏马 马儿|horse horses pony|manian xiaoma||t:animal/plush-horse
    goat|羊年 小羊 山羊 绵羊 羊羊|goat goats sheep lamb|yangnian xiaoyang||t:animal/plush-goat
    monkey|猴年 猴子 小猴|monkey monkeys|hounian houzi||t:animal/plush-monkey
    rooster|鸡年 小鸡 公鸡 鸡仔|rooster chicken chick|xiaoji gongji||t:animal/plush-rooster
    pig|猪年 小猪 猪猪 佩奇|pig pigs piggy peppa|zhunian xiaozhu zhuzhu||t:animal/plush-pig
    zodiac|生肖 十二生肖 属相|zodiac|shengxiao shuxiang||t:animal/plush-dragon t:animal/plush-tiger t:animal/plush-rabbit
    food|美食 菜谱 食谱 料理 做饭 下厨 餐厅 外卖 好吃 小吃 吃的 探店|food foods foodie recipes recipe cooking cook kitchen restaurant restaurants|meishi caipu shipu liaoli zuofan||t:food/ramen t:food/sushi s:fork.knife:orange
    baking|烘焙 蛋糕 甜品 甜点 面包 西点 点心 下午茶 生日 烘培 裱花|baking bake bakery cake cakes dessert desserts bread pastry pastries birthday|hongbei dangao tianpin tiandian mianbao xidian shengri||t:food/cake t:food/donut s:birthday.cake.fill:pink
    ramen|拉面 面条 面馆|ramen noodle noodles|lamian miantiao||t:food/ramen
    sushi|寿司 日料 刺身|sushi sashimi|shousi riliao||t:food/sushi
    matcha|抹茶 绿茶 奶茶 茶叶 喝茶 茶|matcha tea mocha|lvcha naicha chaye||t:food/matcha s:cup.and.saucer.fill:pine
    coffee|咖啡 拿铁 咖啡馆|coffee cafe latte espresso|kafei||s:cup.and.saucer.fill:wheat t:material/wood
    watermelon|西瓜 水果 夏天 夏日|watermelon fruit fruits summer|xigua shuiguo xiatian||t:food/watermelon s:sun.max.fill:wheat
    donut|甜甜圈|donut donuts doughnut doughnuts|tiantianquan||t:food/donut
    space|太空 宇宙 星空 天文 星星 星座 银河 宇航 航天 外星 宇航员|space universe galaxy cosmos stars astronomy nasa astronaut alien aliens ufo|taikong yuzhou xingkong tianwen xingzuo yinhe||t:starry/galaxy t:planet/astronaut t:starry/constellation t:planet/ufo
    moon|月亮 月球 夜晚 晚安 中秋 夜景|moon lunar night nights|yueliang yueqiu zhongqiu||t:starry/moon t:starry/moon-2 s:moon.stars.fill:lilac
    aurora|极光 冰岛 北欧|aurora iceland nordic|jiguang bingdao||t:starry/aurora
    meteor|流星 许愿 愿望 心愿|meteor shooting_star wish wishes wishlist|liuxing xuyuan yuanwang||t:starry/shooting-star t:starry/shooting-star-2 t:starry/stars
    planet|星球 行星|planet planets|xingqiu||t:planet/saturn t:planet/pastel t:planet/earth
    earth|地球 环保 世界 全球 地图|earth world global globe map maps|diqiu shijie||t:planet/earth s:globe.asia.australia.fill:sky s:map.fill:pine
    mars|火星|mars|huoxing||t:planet/mars t:planet/rover
    saturn|土星|saturn|tuxing||t:planet/saturn
    jupiter|木星|jupiter|muxing||t:planet/jupiter
    plants|植物 绿植 花园 园艺 花草 花卉 鲜花 花朵 插花 种花 养花|plants plant garden gardening flowers flower botany|zhiwu lvzhi huayuan yuanyi xianhua||t:plant/monstera t:plant/tulip s:leaf.fill:pine
    succulent|多肉 仙人掌|succulent succulents cactus|duorou xianrenzhang||t:plant/succulent
    bonsai|盆栽 盆景|bonsai|penzai penjing||t:plant/bonsai
    sunflower|向日葵|sunflower sunflowers|xiangrikui||t:plant/sunflower
    tulip|郁金香|tulip tulips|yujinxiang||t:plant/tulip
    palm|椰子 棕榈 热带 海岛|palm palms tropical island coconut|yezi zonglv redai haidao||t:plant/palm
    architecture|建筑 地标 城市 古建|architecture building buildings landmark landmarks city cities|jianzhu dibiao chengshi||t:building/opera-house t:building/eiffel s:building.columns.fill:silver
    paris|巴黎 法国 埃菲尔|paris france french eiffel|faguo||t:building/eiffel
    london|伦敦 英国 大本钟|london england british big_ben|lundun yingguo||t:building/big-ben
    newyork|纽约 美国 自由女神|new_york newyork nyc usa america liberty|niuyue meiguo||t:building/liberty
    sydney|悉尼 澳洲 澳大利亚 歌剧院|sydney australia opera|xini aozhou||t:building/opera-house
    india|印度 泰姬陵|india taj_mahal|yindu||t:building/taj-mahal
    egypt|埃及 金字塔|egypt pyramid pyramids cairo|aiji jinzita||t:building/pyramids
    wood|木头 木纹 原木 实木 木工|wood wooden woodwork|mutou muwen||t:material/wood
    marble|大理石 石材 石头|marble stone stones|dalishi shicai||t:material/marble
    metal|金属 五金|metal metals steel|jinshu wujin||t:material/metal
    glass|玻璃 磨砂 毛玻璃|glass frosted|boli mosha||t:material/frosted-glass
    gradient|渐变 渐层|gradient gradients|jianbian||t:material/gradient-glass
    holographic|镭射 幻彩 全息 炫彩|holographic hologram iridescent|leishe huancai quanxi||t:material/holographic
    apple|苹果 果粉 苹果电脑|apple mac macos macbook iphone ipad imac wwdc|pingguo||t:apple/macintosh t:apple/retro-rainbow t:apple/imac-g3
    retro|复古 怀旧 老电脑 老物件|retro vintage classic nostalgia|fugu huaijiu jingdian||t:apple/retro-cream t:apple/apple-ii t:apple/powerbook
    games|游戏 电玩 手游 主机游戏 网游 单机|games game gaming steam nintendo playstation xbox|youxi shouyou||s:gamecontroller.fill:lilac s:puzzlepiece.fill:orange s:dice.fill:coral
    apps|软件 应用 应用程序 安装包 安装程序 工具 插件 破解|apps app applications application software installers installer dmg pkg tools tool utilities plugins plugin|ruanjian yingyong anzhuangbao gongju chajian||s:app.badge.fill:sky s:shippingbox.fill:wheat s:wrench.and.screwdriver.fill:graphite
    ai|人工智能 提示词 智能 大模型|ai aigc chatgpt gpt codex claude gemini midjourney prompt prompts llm|rengongzhineng tishici damoxing||s:sparkles:lilac s:brain.head.profile:pink s:wand.and.stars:sky
    health|健康 医疗 医院 体检 病历 看病 药品 用药 牙医 报告单 化验|health medical hospital doctor dental pharmacy|jiankang yiliao yiyuan tijian bingli||s:cross.case.fill:coral s:heart.text.square.fill:pink s:pills.fill:sky
    fitness|健身 运动 跑步 锻炼 瑜伽 减肥 骑行 登山 球赛|fitness gym workout workouts running sports sport yoga cycling hiking|jianshen yundong paobu duanlian yujia jianfei||s:dumbbell.fill:graphite s:figure.run:orange s:sportscourt.fill:pine
    important|重要 紧急 待办 待处理 加急 急件|important urgent priority todo todos to_do|zhongyao jinji daiban||s:exclamationmark.triangle.fill:orange s:flag.fill:coral s:checklist:sky
    favorites|收藏 精选 常用 喜欢 最爱 珍藏 宝藏|favorites favourites favorite favourite fav favs faves starred best|shoucang jingxuan changyong zuiai||s:star.fill:wheat s:heart.fill:pink s:bookmark.fill:coral
    temp|临时 暂存 杂项 杂物 其他 其它 未分类 待整理 收件箱 中转|temp tmp temporary misc inbox scratch other others unsorted|linshi zancun zaxiang qita daizhengli||s:tray.full.fill:silver s:hourglass:wheat s:clock.fill:graphite
    cloud|同步 网盘 云盘 云端 百度网盘 坚果云|sync cloud icloud dropbox onedrive gdrive google_drive nutstore|tongbu wangpan yunpan||s:icloud.fill:sky s:cloud.fill:silver s:arrow.triangle.2.circlepath:pine
    chat|微信 聊天 消息 邮件 钉钉 飞书 企业微信 聊天记录|wechat chat chats messages message mail email emails telegram slack whatsapp qq|weixin liaotian xiaoxi youjian dingding feishu|wx|s:bubble.left.and.bubble.right.fill:pine s:message.fill:sky s:envelope.fill:orange
    sales|销售 市场 营销 推广 广告 运营 报价 订单 电商 业绩 促销|sales marketing ads advertising orders order quote quotes quotation promo promotion ecommerce|xiaoshou shichang yingxiao tuiguang guanggao yunying baojia dingdan dianshang yeji||s:chart.line.uptrend.xyaxis:pine s:cart.fill:orange s:megaphone.fill:coral
    presentation|演示 幻灯片 汇报 演讲 路演 讲稿|ppt keynote slides slide presentation presentations deck pitch|yanshi huandengpian huibao yanjiang luyan||s:display:sky s:chart.bar.fill:orange s:doc.richtext.fill:lilac
    private|私人 隐私 私密 机密 密码 保密 秘密|private privacy secret secrets confidential password passwords|siren yinsi simi jimi mima baomi||s:lock.fill:graphite s:key.fill:wheat s:shield.fill:sky
    personal|证件 身份证 简历 个人 户口 驾照 毕业证 证书|resume cv personal identity certificates certificate|zhengjian shenfenzheng jianli geren zhengshu||s:person.crop.circle.fill:sky s:checkmark.seal.fill:pine s:doc.text.fill:silver
    share|公共 共享 分享 对外|public shared share sharing|gonggong gongxiang fenxiang||s:person.3.fill:sky s:link:pine s:paperplane.fill:orange
    plan|日程 计划 日历 安排 排期 规划 待安排|plan plans planning schedule calendar agenda roadmap|richeng jihua rili anpai guihua||s:calendar:coral s:checklist:pine s:clock.fill:sky
    events|活动 聚会 派对 年会 展会 晚会 庆典 节日|event events party parties expo festival celebration|huodong juhui paidui nianhui zhanhui||s:gift.fill:pink s:sparkles:wheat s:calendar:sky
    """
}
