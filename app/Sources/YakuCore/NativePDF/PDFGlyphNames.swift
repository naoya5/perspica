import Foundation

/// Glyph names to Unicode, and the three predefined single-byte encodings of
/// ISO 32000 Annex D. The tables are hand-written from the specification; no
/// Adobe data files are shipped.
public enum PDFGlyphNames {
    /// Unicode text for a glyph name, or nil when the name is unknown.
    ///
    /// Handles `uniXXXX` (one or more groups of four hex digits), `uXXXX` to
    /// `uXXXXXX`, names with a variant suffix (`a.sc` is `a`), ligature parts
    /// joined with an underscore (`f_i` is `fi`) and accented Latin letters
    /// built from a base letter and an accent name (`eacute`).
    public static func unicode(for name: String) -> String? {
        guard !name.isEmpty else { return nil }
        // A suffix after a period marks a variant of the same character.
        if let dot = name.firstIndex(of: ".") {
            return unicode(for: String(name[name.startIndex..<dot]))
        }
        if name.contains("_") {
            let parts = name.split(separator: "_").map { unicode(for: String($0)) }
            guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
            return parts.compactMap { $0 }.joined()
        }
        if let text = hexadecimalName(name) { return text }
        if let text = table[name] { return text }
        return accented(name)
    }

    /// Glyph names of a predefined encoding, indexed by character code, or nil
    /// for an unknown encoding name. Undefined codes hold an empty string.
    public static func encoding(named name: String) -> [String]? {
        switch name {
        case "WinAnsiEncoding": return winAnsi
        case "MacRomanEncoding": return macRoman
        case "StandardEncoding": return standard
        default: return nil
        }
    }

    // MARK: - Names spelled with hexadecimal digits

    private static func hexadecimalName(_ name: String) -> String? {
        if name.hasPrefix("uni") {
            let digits = name.dropFirst(3)
            guard digits.count >= 4, digits.count % 4 == 0, digits.allSatisfy(isHexDigit) else { return nil }
            var text = ""
            var start = digits.startIndex
            while start < digits.endIndex {
                let end = digits.index(start, offsetBy: 4)
                guard let value = UInt32(digits[start..<end], radix: 16),
                      let scalar = Unicode.Scalar(value) else { return nil }
                text.unicodeScalars.append(scalar)
                start = end
            }
            return text
        }
        if name.hasPrefix("u") {
            let digits = name.dropFirst()
            guard (4...6).contains(digits.count), digits.allSatisfy(isHexDigit),
                  let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value) else { return nil }
            return String(scalar)
        }
        return nil
    }

    private static func isHexDigit(_ character: Character) -> Bool {
        character.isASCII && character.isHexDigit
    }

    // MARK: - Accented Latin letters

    /// Accent suffixes, longest first so that a name matches the most specific one.
    private static let accents: [(suffix: String, mark: Unicode.Scalar)] = [
        ("hungarumlaut", "\u{030B}"),
        ("circumflex", "\u{0302}"),
        ("dotaccent", "\u{0307}"),
        ("dieresis", "\u{0308}"),
        ("cedilla", "\u{0327}"),
        ("ogonek", "\u{0328}"),
        ("acute", "\u{0301}"),
        ("grave", "\u{0300}"),
        ("tilde", "\u{0303}"),
        ("breve", "\u{0306}"),
        ("macron", "\u{0304}"),
        ("caron", "\u{030C}"),
        ("slash", "\u{0338}"),
        ("ring", "\u{030A}"),
    ]

    private static func accented(_ name: String) -> String? {
        for (suffix, mark) in accents {
            guard name.count > suffix.count, name.hasSuffix(suffix) else { continue }
            let base = String(name.dropLast(suffix.count))
            guard base.count == 1, let letter = base.unicodeScalars.first,
                  CharacterSet.letters.contains(letter) else { continue }
            let composed = (String(letter) + String(Character(mark))).precomposedStringWithCanonicalMapping
            if composed.unicodeScalars.count == 1 { return composed }
        }
        return nil
    }

    // MARK: - Glyph name table

    /// `name hex` lines. ASCII letters and the digit names are generated below.
    private static let namedGlyphs = """
        space 0020
        exclam 0021
        quotedbl 0022
        numbersign 0023
        dollar 0024
        percent 0025
        ampersand 0026
        quotesingle 0027
        parenleft 0028
        parenright 0029
        asterisk 002A
        plus 002B
        comma 002C
        hyphen 002D
        period 002E
        slash 002F
        colon 003A
        semicolon 003B
        less 003C
        equal 003D
        greater 003E
        question 003F
        at 0040
        bracketleft 005B
        backslash 005C
        bracketright 005D
        asciicircum 005E
        underscore 005F
        grave 0060
        braceleft 007B
        bar 007C
        braceright 007D
        asciitilde 007E
        exclamdown 00A1
        cent 00A2
        sterling 00A3
        currency 00A4
        yen 00A5
        brokenbar 00A6
        section 00A7
        dieresis 00A8
        copyright 00A9
        ordfeminine 00AA
        guillemotleft 00AB
        logicalnot 00AC
        registered 00AE
        macron 00AF
        degree 00B0
        plusminus 00B1
        twosuperior 00B2
        threesuperior 00B3
        acute 00B4
        mu 00B5
        paragraph 00B6
        periodcentered 00B7
        cedilla 00B8
        onesuperior 00B9
        ordmasculine 00BA
        guillemotright 00BB
        onequarter 00BC
        onehalf 00BD
        threequarters 00BE
        questiondown 00BF
        multiply 00D7
        divide 00F7
        AE 00C6
        ae 00E6
        OE 0152
        oe 0153
        germandbls 00DF
        Thorn 00DE
        thorn 00FE
        Eth 00D0
        eth 00F0
        Yacute 00DD
        yacute 00FD
        Ydieresis 0178
        florin 0192
        dotlessi 0131
        dotlessj 0237
        Lslash 0141
        lslash 0142
        Oslash 00D8
        oslash 00F8
        nbspace 00A0
        sfthyphen 00AD
        quoteleft 2018
        quoteright 2019
        quotedblleft 201C
        quotedblright 201D
        quotesinglbase 201A
        quotedblbase 201E
        quotereversed 201B
        guilsinglleft 2039
        guilsinglright 203A
        endash 2013
        emdash 2014
        figuredash 2012
        bullet 2022
        ellipsis 2026
        dagger 2020
        daggerdbl 2021
        perthousand 2030
        fraction 2044
        minus 2212
        trademark 2122
        servicemark 2120
        Euro 20AC
        lozenge 25CA
        apple F8FF
        minute 2032
        second 2033
        numero 2116
        estimated 212E
        ff FB00
        fi FB01
        fl FB02
        ffi FB03
        ffl FB04
        alpha 03B1
        beta 03B2
        gamma 03B3
        delta 03B4
        epsilon 03B5
        zeta 03B6
        eta 03B7
        theta 03B8
        iota 03B9
        kappa 03BA
        lambda 03BB
        nu 03BD
        xi 03BE
        omicron 03BF
        pi 03C0
        rho 03C1
        sigma 03C3
        sigma1 03C2
        tau 03C4
        upsilon 03C5
        phi 03C6
        chi 03C7
        psi 03C8
        omega 03C9
        Alpha 0391
        Beta 0392
        Gamma 0393
        Delta 0394
        Epsilon 0395
        Zeta 0396
        Eta 0397
        Theta 0398
        Iota 0399
        Kappa 039A
        Lambda 039B
        Mu 039C
        Nu 039D
        Xi 039E
        Omicron 039F
        Pi 03A0
        Rho 03A1
        Sigma 03A3
        Tau 03A4
        Upsilon 03A5
        Phi 03A6
        Chi 03A7
        Psi 03A8
        Omega 03A9
        infinity 221E
        summation 2211
        integral 222B
        radical 221A
        lessequal 2264
        greaterequal 2265
        notequal 2260
        approxequal 2248
        element 2208
        arrowright 2192
        arrowleft 2190
        arrowup 2191
        arrowdown 2193
        arrowboth 2194
        arrowdblleft 21D0
        arrowdblright 21D2
        partialdiff 2202
        nabla 2207
        gradient 2207
        increment 2206
        product 220F
        minusplus 2213
        equivalence 2261
        similar 223C
        congruent 2245
        propersubset 2282
        reflexsubset 2286
        propersuperset 2283
        reflexsuperset 2287
        intersection 2229
        union 222A
        universal 2200
        existential 2203
        emptyset 2205
        logicaland 2227
        logicalor 2228
        therefore 2234
        perpendicular 22A5
        angle 2220
        dotmath 22C5
        asteriskmath 2217
        circleplus 2295
        circlemultiply 2297
        suchthat 220B
        aleph 2135
        weierstrass 2118
        Ifraktur 2111
        Rfraktur 211C
        floorleft 230A
        floorright 230B
        ceilingleft 2308
        ceilingright 2309
        """

    private static let table: [String: String] = {
        var table: [String: String] = [:]
        for line in namedGlyphs.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let value = UInt32(parts[1], radix: 16),
                  let scalar = Unicode.Scalar(value) else { continue }
            table[String(parts[0])] = String(scalar)
        }
        // ASCII letters are named after the character itself; digits are spelled out.
        for value in Array(0x41...0x5A) + Array(0x61...0x7A) {
            guard let scalar = Unicode.Scalar(UInt32(value)) else { continue }
            table[String(scalar)] = String(scalar)
        }
        let digits = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        for (offset, name) in digits.enumerated() {
            table[name] = String(offset)
        }
        return table
    }()

    // MARK: - Predefined encodings

    /// Builds a 256 entry code to glyph name table from `start, "name name ..."`
    /// segments. A "-" leaves the code undefined.
    private static func encodingTable(_ segments: [(Int, String)]) -> [String] {
        var codes = [String](repeating: "", count: 256)
        for (start, names) in segments {
            for (offset, name) in names.split(separator: " ").enumerated() {
                guard start + offset < codes.count, name != "-" else { continue }
                codes[start + offset] = String(name)
            }
        }
        return codes
    }

    /// ISO 32000 Annex D.2, WinAnsiEncoding (code page 1252 with PDF's own
    /// assignments for the quotes and the non-breaking space).
    private static let winAnsi = encodingTable([
        (32, "space exclam quotedbl numbersign dollar percent ampersand quotesingle parenleft parenright asterisk plus comma hyphen period slash"),
        (48, "zero one two three four five six seven eight nine"),
        (58, "colon semicolon less equal greater question at"),
        (65, "A B C D E F G H I J K L M N O P Q R S T U V W X Y Z"),
        (91, "bracketleft backslash bracketright asciicircum underscore grave"),
        (97, "a b c d e f g h i j k l m n o p q r s t u v w x y z"),
        (123, "braceleft bar braceright asciitilde"),
        (128, "Euro - quotesinglbase florin quotedblbase ellipsis dagger daggerdbl circumflex perthousand Scaron guilsinglleft OE - Zcaron - - quoteleft quoteright quotedblleft quotedblright bullet endash emdash tilde trademark scaron guilsinglright oe - zcaron Ydieresis"),
        (160, "space exclamdown cent sterling currency yen brokenbar section dieresis copyright ordfeminine guillemotleft logicalnot hyphen registered macron degree plusminus twosuperior threesuperior acute mu paragraph periodcentered cedilla onesuperior ordmasculine guillemotright onequarter onehalf threequarters questiondown"),
        (192, "Agrave Aacute Acircumflex Atilde Adieresis Aring AE Ccedilla Egrave Eacute Ecircumflex Edieresis Igrave Iacute Icircumflex Idieresis Eth Ntilde Ograve Oacute Ocircumflex Otilde Odieresis multiply Oslash Ugrave Uacute Ucircumflex Udieresis Yacute Thorn germandbls"),
        (224, "agrave aacute acircumflex atilde adieresis aring ae ccedilla egrave eacute ecircumflex edieresis igrave iacute icircumflex idieresis eth ntilde ograve oacute ocircumflex otilde odieresis divide oslash ugrave uacute ucircumflex udieresis yacute thorn ydieresis"),
    ])

    /// ISO 32000 Annex D.2, MacRomanEncoding.
    private static let macRoman = encodingTable([
        (32, "space exclam quotedbl numbersign dollar percent ampersand quotesingle parenleft parenright asterisk plus comma hyphen period slash"),
        (48, "zero one two three four five six seven eight nine"),
        (58, "colon semicolon less equal greater question at"),
        (65, "A B C D E F G H I J K L M N O P Q R S T U V W X Y Z"),
        (91, "bracketleft backslash bracketright asciicircum underscore grave"),
        (97, "a b c d e f g h i j k l m n o p q r s t u v w x y z"),
        (123, "braceleft bar braceright asciitilde"),
        (128, "Adieresis Aring Ccedilla Eacute Ntilde Odieresis Udieresis aacute agrave acircumflex adieresis atilde aring ccedilla eacute egrave ecircumflex edieresis iacute igrave icircumflex idieresis ntilde oacute ograve ocircumflex odieresis otilde uacute ugrave ucircumflex udieresis dagger degree cent sterling section bullet paragraph germandbls registered copyright trademark acute dieresis notequal AE Oslash infinity plusminus lessequal greaterequal yen mu partialdiff summation product pi integral ordfeminine ordmasculine Omega ae oslash questiondown exclamdown logicalnot radical florin approxequal Delta guillemotleft guillemotright ellipsis space Agrave Atilde Otilde OE oe endash emdash quotedblleft quotedblright quoteleft quoteright divide lozenge ydieresis Ydieresis fraction currency guilsinglleft guilsinglright fi fl daggerdbl periodcentered quotesinglbase quotedblbase perthousand Acircumflex Ecircumflex Aacute Edieresis Egrave Iacute Icircumflex Idieresis Igrave Oacute Ocircumflex apple Ograve Uacute Ucircumflex Ugrave dotlessi circumflex tilde macron breve dotaccent ring cedilla hungarumlaut ogonek caron"),
    ])

    /// ISO 32000 Annex D.2, StandardEncoding.
    private static let standard = encodingTable([
        (32, "space exclam quotedbl numbersign dollar percent ampersand quoteright parenleft parenright asterisk plus comma hyphen period slash"),
        (48, "zero one two three four five six seven eight nine"),
        (58, "colon semicolon less equal greater question at"),
        (65, "A B C D E F G H I J K L M N O P Q R S T U V W X Y Z"),
        (91, "bracketleft backslash bracketright asciicircum underscore quoteleft"),
        (97, "a b c d e f g h i j k l m n o p q r s t u v w x y z"),
        (123, "braceleft bar braceright asciitilde"),
        (161, "exclamdown cent sterling fraction yen florin section currency quotesingle quotedblleft guillemotleft guilsinglleft guilsinglright fi fl - endash dagger daggerdbl periodcentered - paragraph bullet quotesinglbase quotedblbase quotedblright guillemotright ellipsis perthousand - questiondown - grave acute circumflex tilde macron breve dotaccent dieresis - ring cedilla - hungarumlaut ogonek caron emdash"),
        (225, "AE - ordfeminine - - - - Lslash Oslash OE ordmasculine - - - - - ae - - - dotlessi - - lslash oslash oe germandbls"),
    ])
}
