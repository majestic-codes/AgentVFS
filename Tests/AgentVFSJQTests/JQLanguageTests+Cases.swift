//
//  JQLanguageTests+Cases.swift
//  AgentVFSJQTests
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

extension JQLanguageTests {
    static let indexingCases: [JQCase] = [
        JQCase(".", "{\"a\":1,\"b\":[1,2]}", "{\"a\":1,\"b\":[1,2]}"),
        JQCase(".a", "{\"a\":{\"b\":2}}", "{\"b\":2}"),
        JQCase(".a.b", "{\"a\":{\"b\":2}}", "2"),
        JQCase(".\"a b\"", "{\"a b\":3}", "3"),
        JQCase(".[\"a\"]", "{\"a\":1}", "1"),
        JQCase(".a?", "[1]", ""),
        JQCase(".[0]", "[1,2,3]", "1"),
        JQCase(".[-1]", "[1,2,3]", "3"),
        JQCase(".[10]", "[1,2,3]", "null"),
        JQCase(".[1:]", "[1,2,3]", "[2,3]"),
        JQCase(".[:-1]", "[1,2,3]", "[1,2]"),
        JQCase(".[1:2]", "\"abc\"", "\"b\""),
        JQCase(".[]", "[1,[2],{\"a\":3}]", "1\n[2]\n{\"a\":3}"),
        JQCase(".[]", "{\"a\":1,\"b\":2}", "1\n2"),
        JQCase(".[]?", "1", ""),
        JQCase("[.[] | .a?]", "[1,{\"a\":2}]", "[2]"),
        JQCase(".a[]", "{\"a\":[1,2]}", "1\n2"),
        JQCase(".[1][0]", "[0,[5,6]]", "5"),
        JQCase("[.[] | .name]", "[{\"name\":\"x\"},{\"name\":\"y\"}]", "[\"x\",\"y\"]"),
        JQCase("..", "[1,[2]]", "[1,[2]]\n1\n[2]\n2"),
        JQCase("[..|numbers]", "{\"a\":[1,{\"b\":2}],\"c\":\"x\"}", "[1,2]"),
        JQCase("[.[]?]", "\"x\"", "[]"),
        JQCase(".a.b.c", "{}", "null"),
        JQCase("null|.a", "null", "null"),
        JQCase(".[2:4] = [\"x\"]", "[0,1,2,3,4]", "[0,1,\"x\",4]")
    ]

    static let operatorsCases: [JQCase] = [
        JQCase("1 + 2 * 3 - 4 / 2", "null", "5"),
        JQCase("[10 % 3, -10 % 3, 10.5 % 3]", "null", "[1,-1,1]"),
        JQCase("\"a\" + \"b\"", "null", "\"ab\""),
        JQCase("[1,2] + [3]", "null", "[1,2,3]"),
        JQCase("{\"a\":1} + {\"b\":2}", "null", "{\"a\":1,\"b\":2}"),
        JQCase("{\"a\":{\"b\":1}} * {\"a\":{\"c\":2}}", "null", "{\"a\":{\"b\":1,\"c\":2}}"),
        JQCase("[1,2,3,1] - [1]", "null", "[2,3]"),
        JQCase("\"a,b,c\" / \",\"", "null", "[\"a\",\"b\",\"c\"]"),
        JQCase("\"ab\" * 3", "null", "\"ababab\""),
        JQCase("null + 1", "null", "1"),
        JQCase(
            "[1 == 1.0, \"a\" < \"b\", [] < {}, null < false, {\"a\":1} == {\"a\":1}]",
            "null",
            "[true,true,true,true,true]"
        ),
        JQCase("[(1,2) + (10,20)]", "null", "[11,12,21,22]"),
        JQCase("[.[] | -.]", "[1,-2]", "[-1,2]"),
        JQCase("[true and false, true or false, (null | not)]", "null", "[false,true,true]"),
        JQCase("[.[] // \"default\"]", "[[null],[false],[1]]", "[[null],[false],[1]]"),
        JQCase(".a // .b // \"none\"", "{\"b\":2}", "2"),
        JQCase("[.[] | (.a // 0)]", "[{\"a\":1},{}]", "[1,0]")
    ]

    static let constructionCases: [JQCase] = [
        JQCase("[.a, .b]", "{\"a\":1,\"b\":2}", "[1,2]"),
        JQCase("{a, b: .a, \"c d\": 3, (.k): 4}", "{\"a\":1,\"k\":\"key\"}", "{\"a\":1,\"b\":1,\"c d\":3,\"key\":4}"),
        JQCase("{\"\\(.k)x\": 1}", "{\"k\":\"a\"}", "{\"ax\":1}"),
        JQCase(
            "[{a: (1,2), b: (3,4)}]",
            "null",
            "[{\"a\":1,\"b\":3},{\"a\":1,\"b\":4},{\"a\":2,\"b\":3},{\"a\":2,\"b\":4}]"
        ),
        JQCase("{(.[] | tostring): true}", "[1,2]", "{\"1\":true}\n{\"2\":true}"),
        JQCase("\"x=\\(.x) y=\\(.y + 1)\"", "{\"x\":\"a\",\"y\":1}", "\"x=a y=2\""),
        JQCase(
            "[.[] | \"\\(.)\"]",
            "[1,\"s\",null,[1],{\"a\":true}]",
            "[\"1\",\"s\",\"null\",\"[1]\",\"{\\\"a\\\":true}\"]"
        ),
        JQCase("@base64 \"v=\\(.)\"", "\"hi\"", "\"v=aGk=\"")
    ]

    static let errorsCases: [JQCase] = [
        JQCase("if . > 1 then \"big\" elif . == 1 then \"one\" else \"small\" end", "1", "\"one\""),
        JQCase("[.[] | if . then \"t\" else \"f\" end]", "[0,false,null,\"\",[]]", "[\"t\",\"f\",\"f\",\"t\",\"t\"]"),
        JQCase("if . then 1 end", "false", "false"),
        JQCase("try error(\"x\") catch .", "null", "\"x\""),
        JQCase(
            "[.[] | try (if . == 2 then error(\"e\\(.)\") else . end) catch \"caught \\(.)\"]",
            "[1,2,3]",
            "[1,\"caught e2\",3]"
        ),
        JQCase(".a?", "\"string\"", ""),
        JQCase("try (\"x\" | error) catch (\"got \" + .)", "null", "\"got x\""),
        JQCase("try error({\"code\":7}) catch .code", "null", "7"),
        JQCase("[.[] | tonumber?]", "[\"1\",\"x\",\"2.5\"]", "[1,2.5]"),
        JQCase("(.a | error)? // \"none\"", "{\"a\":\"bad\"}", "\"none\""),
        JQCase("label $out | 1, 2, break $out, 3", "null", "1\n2"),
        JQCase("[label $f | range(10) | if . > 2 then break $f else . end]", "null", "[0,1,2]")
    ]

    static let functionsCases: [JQCase] = [
        JQCase(". as $x | [$x, $x * 2]", "3", "[3,6]"),
        JQCase(".a as $a | .b as $b | $a + $b", "{\"a\":1,\"b\":2}", "3"),
        JQCase(". as [$a, $b, {c: $c}] | [$a, $b, $c]", "[1,2,{\"c\":3}]", "[1,2,3]"),
        JQCase(". as {a: $x, b: [$y, $z]} | [$x, $y, $z]", "{\"a\":1,\"b\":[2,3]}", "[1,2,3]"),
        JQCase(". as {$a, $b} | $a + $b", "{\"a\":1,\"b\":2}", "3"),
        JQCase("[.[] as [$a] ?// $a | $a]", "[[1],2]", "[1,2]"),
        JQCase("def double: . * 2; [.[] | double]", "[1,2]", "[2,4]"),
        JQCase("def f(g): [g, g]; f(.a)", "{\"a\":1}", "[1,1]"),
        JQCase("def f($a; $b): $a + $b; f(.x; .y)", "{\"x\":1,\"y\":2}", "3"),
        JQCase("def fac: if . <= 1 then 1 else . * (. - 1 | fac) end; fac", "10", "3628800"),
        JQCase(
            "def fib: if . < 2 then . else (. - 1 | fib) + (. - 2 | fib) end; [range(12) | fib]",
            "null",
            "[0,1,1,2,3,5,8,13,21,34,55,89]"
        ),
        JQCase("def f: def g: 3; g * 2; f", "null", "6"),
        JQCase("$__loc__", "null", "{\"file\":\"<top-level>\",\"line\":1}"),
        JQCase("[.[] | . as $x | $x * $x]", "[1,2,3]", "[1,4,9]"),
        JQCase("reduce .[] as $x (0; . + $x)", "[1,2,3,4]", "10"),
        JQCase("reduce .[] as [$k, $v] ({}; .[$k] = $v)", "[[\"a\",1],[\"b\",2]]", "{\"a\":1,\"b\":2}"),
        JQCase("[foreach .[] as $x (0; . + $x)]", "[1,2,3]", "[1,3,6]"),
        JQCase("[foreach .[] as $x (0; . + $x; [$x, .])]", "[1,2,3]", "[[1,1],[2,3],[3,6]]"),
        JQCase("[limit(3; .[])]", "[1,2,3,4,5]", "[1,2,3]"),
        JQCase("[first(.[]), last(.[]), nth(1; .[])]", "[5,6,7]", "[5,7,6]"),
        JQCase(
            "[range(5)], [range(2; 4)], [range(0; 10; 3)], [range(5; 0; -2)]",
            "null",
            "[0,1,2,3,4]\n[2,3]\n[0,3,6,9]\n[5,3,1]"
        ),
        JQCase("[.[] | select(. > 2)]", "[1,2,3,4]", "[3,4]"),
        JQCase("[recurse(if . < 3 then . + 1 else empty end)]", "0", "[0,1,2,3]"),
        JQCase("[2 | recurse(. * .; . < 100)]", "null", "[2,4,16]"),
        JQCase("[limit(4; repeat(. * 2))]", "1", "[2,4,8,16]"),
        JQCase("[.[] | until(. > 100; . * 2)]", "[1,50]", "[128,200]"),
        JQCase("[1 | while(. < 50; . * 3)]", "null", "[1,3,9,27]"),
        JQCase("isempty(empty), isempty(.[])", "[1]", "true\nfalse"),
        JQCase("[any, all]", "[true,false]", "[true,false]"),
        JQCase("[any(.[]; . > 2), all(.[]; . > 0)]", "[1,2,3]", "[true,true]")
    ]

    static let assignmentCases: [JQCase] = [
        JQCase("[paths]", "{\"a\":[1,{\"b\":2}]}", "[[\"a\"],[\"a\",0],[\"a\",1],[\"a\",1,\"b\"]]"),
        JQCase("[paths(type == \"number\")]", "{\"a\":[1,{\"b\":2}]}", "[[\"a\",0],[\"a\",1,\"b\"]]"),
        JQCase("path(.a[0].b)", "null", "[\"a\",0,\"b\"]"),
        JQCase("[path(..)]", "{\"a\":[1]}", "[[],[\"a\"],[\"a\",0]]"),
        JQCase("getpath([\"a\",\"b\"])", "{\"a\":{\"b\":5}}", "5"),
        JQCase("setpath([\"a\",\"b\"]; 1)", "null", "{\"a\":{\"b\":1}}"),
        JQCase("delpaths([[\"a\"],[\"b\",0]])", "{\"a\":1,\"b\":[1,2],\"c\":3}", "{\"b\":[2],\"c\":3}"),
        JQCase("del(.a, .c)", "{\"a\":1,\"b\":2,\"c\":3}", "{\"b\":2}"),
        JQCase("del(.[] | select(. > 1))", "[1,2,3,1]", "[1,1]"),
        JQCase("to_entries", "{\"a\":1,\"b\":2}", "[{\"key\":\"a\",\"value\":1},{\"key\":\"b\",\"value\":2}]"),
        JQCase(
            "from_entries",
            "[{\"key\":\"a\",\"value\":1},{\"name\":\"b\",\"value\":2},{\"Key\":\"c\",\"Value\":3}]",
            "{\"a\":1,\"b\":2,\"c\":3}"
        ),
        JQCase("with_entries(.value += 1)", "{\"a\":1,\"b\":2}", "{\"a\":2,\"b\":3}"),
        JQCase("pick(.a.b, .c)", "{\"a\":{\"b\":1,\"x\":2},\"c\":3,\"d\":4}", "{\"a\":{\"b\":1},\"c\":3}"),
        JQCase(".a = 1", "{}", "{\"a\":1}"),
        JQCase(".a.b |= . + 1", "{\"a\":{\"b\":1}}", "{\"a\":{\"b\":2}}"),
        JQCase(".[] += 10", "[1,2]", "[11,12]"),
        JQCase(".a //= \"d\"", "{\"a\":null}", "{\"a\":\"d\"}"),
        JQCase(
            ".items[].price *= 2",
            "{\"items\":[{\"price\":1},{\"price\":2}]}",
            "{\"items\":[{\"price\":2},{\"price\":4}]}"
        ),
        JQCase("(.a, .b) = (1, 2)", "{}", "{\"a\":1,\"b\":1}\n{\"a\":2,\"b\":2}"),
        JQCase(".[] |= empty", "[1,2,3]", "[]"),
        JQCase("map_values(. * 10)", "{\"a\":1,\"b\":2}", "{\"a\":10,\"b\":20}"),
        JQCase("map(select(. != null))", "[1,null,2]", "[1,2]"),
        JQCase(".a[1:] = [\"x\"]", "{\"a\":[1,2,3]}", "{\"a\":[1,\"x\"]}"),
        JQCase("to_entries | map(select(.value > 1)) | from_entries", "{\"a\":1,\"b\":2,\"c\":3}", "{\"b\":2,\"c\":3}"),
        JQCase("tostream", "{\"a\":[1,2]}", "[[\"a\",0],1]\n[[\"a\",1],2]\n[[\"a\",1]]\n[[\"a\"]]"),
        JQCase("fromstream(tostream)", "{\"a\":[1,{\"b\":null}]}", "{\"a\":[1,{\"b\":null}]}"),
        JQCase("[1|truncate_stream([[0],1],[[1,0],2],[[1,0]],[[1]])]", "null", "[[[0],2],[[0]]]")
    ]

    static let builtinsCases: [JQCase] = [
        JQCase("[length, utf8bytelength]", "\"héllo\"", "[5,6]"),
        JQCase("[.[] | length]", "[[1,2],\"abc\",{\"a\":1},null,-5]", "[2,3,1,0,5]"),
        JQCase("keys, keys_unsorted", "{\"b\":1,\"a\":2}", "[\"a\",\"b\"]\n[\"b\",\"a\"]"),
        JQCase("[has(\"a\"), has(\"z\")]", "{\"a\":1}", "[true,false]"),
        JQCase("[has(0), has(5)]", "[1]", "[true,false]"),
        JQCase("[.[] | in({\"a\":1})]", "[\"a\",\"b\"]", "[true,false]"),
        JQCase(
            "map(type)",
            "[0,\"a\",[],{},null,true]",
            "[\"number\",\"string\",\"array\",\"object\",\"null\",\"boolean\"]"
        ),
        JQCase("[.[] | numbers]", "[1,\"a\",2]", "[1,2]"),
        JQCase("[.[] | strings, booleans, nulls]", "[1,\"a\",true,null]", "[\"a\",true,null]"),
        JQCase("[.[] | iterables]", "[1,[],{}]", "[[],{}]"),
        JQCase("[.[] | scalars]", "[1,[],\"x\"]", "[1,\"x\"]"),
        JQCase("add", "[1,2,3]", "6"),
        JQCase("add", "[\"a\",\"b\"]", "\"ab\""),
        JQCase("add", "[[1],[2]]", "[1,2]"),
        JQCase("add", "[{\"a\":1},{\"b\":2}]", "{\"a\":1,\"b\":2}"),
        JQCase("add", "[]", "null"),
        JQCase("[flatten, flatten(1)]", "[1,[2,[3,[4]]]]", "[[1,2,3,4],[1,2,[3,[4]]]]"),
        JQCase("[min, max]", "[3,1,2]", "[1,3]"),
        JQCase("[min_by(.a), max_by(.a)]", "[{\"a\":2},{\"a\":1},{\"a\":3}]", "[{\"a\":1},{\"a\":3}]"),
        JQCase("sort", "[3,\"a\",null,true,[1],{\"a\":1},1]", "[null,true,1,3,\"a\",[1],{\"a\":1}]"),
        JQCase(
            "sort_by(.a)",
            "[{\"a\":2,\"b\":1},{\"a\":1,\"b\":2},{\"a\":2,\"b\":0}]",
            "[{\"a\":1,\"b\":2},{\"a\":2,\"b\":1},{\"a\":2,\"b\":0}]"
        ),
        JQCase(
            "sort_by(.a, .b)",
            "[{\"a\":2,\"b\":1},{\"a\":1,\"b\":2},{\"a\":2,\"b\":0}]",
            "[{\"a\":1,\"b\":2},{\"a\":2,\"b\":0},{\"a\":2,\"b\":1}]"
        ),
        JQCase("group_by(.t) | map(length)", "[{\"t\":\"a\"},{\"t\":\"b\"},{\"t\":\"a\"}]", "[2,1]"),
        JQCase("unique", "[3,1,3,2,1]", "[1,2,3]"),
        JQCase("unique_by(length)", "[\"a\",\"bb\",\"c\",\"dd\"]", "[\"a\",\"bb\"]"),
        JQCase("reverse", "[1,2,3]", "[3,2,1]"),
        JQCase("[contains(\"bar\"), contains(\"baz\")]", "\"foobar\"", "[true,false]"),
        JQCase("contains({\"a\":[1]})", "{\"a\":[1,2],\"b\":3}", "true"),
        JQCase("inside([1,2,3])", "[1,3]", "true"),
        JQCase("[indices(1), index(1), rindex(1)]", "[1,2,1]", "[[0,2],0,2]"),
        JQCase("[indices(\", \"), index(\", \"), rindex(\", \")]", "\"a, b, c\"", "[[1,4],1,4]"),
        JQCase("transpose", "[[1,2],[3]]", "[[1,3],[2,null]]"),
        JQCase("[combinations]", "[[1,2],[3,4]]", "[[1,3],[1,4],[2,3],[2,4]]"),
        JQCase("walk(if type == \"number\" then . + 1 else . end)", "{\"a\":[1,{\"b\":2}]}", "{\"a\":[2,{\"b\":3}]}"),
        JQCase("INDEX(.id)", "[{\"id\":\"x\"},{\"id\":\"y\"}]", "{\"x\":{\"id\":\"x\"},\"y\":{\"id\":\"y\"}}"),
        JQCase("[.[] | IN(2, 3)]", "[1,2,3]", "[false,true,true]"),
        JQCase("splits(\", \")", "\"a, b\"", "\"a\"\n\"b\""),
        JQCase("tojson", "{\"a\":[1,\"x\"]}", "\"{\\\"a\\\":[1,\\\"x\\\"]}\""),
        JQCase("fromjson", "\"{\\\"a\\\":1}\"", "{\"a\":1}"),
        JQCase("[.[] | tostring]", "[1,\"a\",[1],null]", "[\"1\",\"a\",\"[1]\",\"null\"]"),
        JQCase("[.[] | tonumber]", "[\"1\",\"2.5\",\"-3e2\",4]", "[1,2.5,-3E+2,4]"),
        JQCase("[infinite, -infinite, nan] | map(isinfinite)", "null", "[true,true,false]"),
        JQCase("[nan] | sort", "null", "[null]"),
        JQCase("getpath([\"x\"]) // \"missing\"", "{}", "\"missing\""),
        JQCase("[splits(\"a+\"; \"g\")]", "\"baaac\"", "[\"b\",\"c\"]"),
        JQCase("env | type", "null", "\"object\""),
        JQCase("$ENV | length", "null", "0"),
        JQCase("input_filename", "null", "\"input.json\""),
        JQCase("[.[] | ascii_downcase, ascii_upcase]", "[\"aBc\"]", "[\"abc\",\"ABC\"]"),
        JQCase(
            "[ltrimstr(\"foo\"), rtrimstr(\"bar\"), startswith(\"foo\"), endswith(\"x\")]",
            "\"foobar\"",
            "[\"bar\",\"foo\",true,false]"
        ),
        JQCase("explode, (explode | implode)", "\"aé😀\"", "[97,233,128512]\n\"aé😀\""),
        JQCase("split(\", \")", "\"a, b, c\"", "[\"a\",\"b\",\"c\"]"),
        JQCase("join(\"-\")", "[\"a\",1,null,true]", "\"a-1--true\""),
        JQCase("[.[] | @text, @json]", "[1,\"a\"]", "[\"1\",\"1\",\"a\",\"\\\"a\\\"\"]"),
        JQCase(
            "@csv, @tsv",
            "[1,\"a,b\",\"c\\\"d\",null,true]",
            "\"1,\\\"a,b\\\",\\\"c\\\"\\\"d\\\",,true\"\n\"1\\ta,b\\tc\\\"d\\t\\ttrue\""
        ),
        JQCase("@html", "\"<a href='x'>&</a>\"", "\"&lt;a href=&apos;x&apos;&gt;&amp;&lt;/a&gt;\""),
        JQCase("@uri", "\"a b/c?d=é\"", "\"a%20b%2Fc%3Fd%3D%C3%A9\""),
        JQCase("@sh", "[\"a b\",\"it's\",1]", "\"'a b' 'it'\\\\''s' 1\""),
        JQCase("@base64, (@base64 | @base64d)", "\"hello world\"", "\"aGVsbG8gd29ybGQ=\"\n\"hello world\""),
        JQCase("[test(\"b\"), test(\"B\"; \"i\"), test(\"^b\")]", "\"abc\"", "[true,true,false]"),
        JQCase(
            "[match(\"a(b)?\"; \"g\") | [.offset, .length, .captures[0].string]]",
            "\"ab a\"",
            "[[0,2,\"b\"],[3,1,null]]"
        ),
        JQCase("capture(\"(?<y>\\\\d+)-(?<m>\\\\d+)\")", "\"2023-06\"", "{\"y\":\"2023\",\"m\":\"06\"}"),
        JQCase("[scan(\"\\\\d+\")], [scan(\"(a)(b)\")]", "\"a1b22ab\"", "[\"1\",\"22\"]\n[[\"a\",\"b\"]]"),
        JQCase("sub(\"(?<x>\\\\w+)\"; \"<\\(.x)>\"), gsub(\"o\"; \"0\")", "\"foo boo\"", "\"<foo> boo\"\n\"f00 b00\""),
        JQCase("gsub(\"(?<c>[aeiou])\"; \"\\(.c | ascii_upcase)\")", "\"education\"", "\"EdUcAtIOn\""),
        JQCase("gsub(\"^\\\\s+|\\\\s+$\"; \"\")", "\"  trim me  \"", "\"trim me\""),
        JQCase("[splits(\", *\")]", "\"a,b, c\"", "[\"a\",\"b\",\"c\"]"),
        JQCase("ascii_downcase | test(\"^[a-z]+$\")", "\"Hello\"", "true")
    ]

    static let mathCases: [JQCase] = [
        JQCase("[floor, ceil, round, fabs, sqrt]", "2.5", "[2,3,3,2.5,1.5811388300841898]"),
        JQCase("[pow(2; 10), log10, (100 | log10), (8 | log2), (1 | exp)]", "1000", "[1024,3,2,3,2.718281828459045]"),
        JQCase("[.[] | round]", "[-1.5,-0.5,0.5,1.5]", "[-2,-1,1,2]"),
        JQCase(
            "[1, 1.0, 1.50, 1e3, 0.1 + 0.2, 1e100, 3.14159, -0, 100000000000000000000]",
            "null",
            "[1,1.0,1.50,1E+3,0.30000000000000004,1E+100,3.14159,-0,100000000000000000000]"
        ),
        JQCase(
            ".[] | . * 1",
            "[1,1.0,1.50,1e3,1e17,1.5e300,0.00001,1e-7]",
            "1\n1\n1.5\n1000\n1e+17\n1.5e+300\n1e-05\n1e-07"
        ),
        JQCase("[10 / 3, 1 / 3, 2 / 4]", "null", "[3.3333333333333335,0.3333333333333333,0.5]")
    ]

    static let datesCases: [JQCase] = [
        JQCase("todate", "1700000000", "\"2023-11-14T22:13:20Z\""),
        JQCase("fromdate", "\"2023-11-14T22:13:20Z\"", "1700000000"),
        JQCase("gmtime", "1700000000.5", "[2023,10,14,22,13,20.5,2,317]"),
        JQCase("gmtime | mktime", "1700000000", "1700000000"),
        JQCase("strftime(\"%Y-%m-%d %H:%M:%S %a %b %j\")", "1700000000", "\"2023-11-14 22:13:20 Tue Nov 318\""),
        JQCase("strptime(\"%Y-%m-%dT%H:%M:%SZ\")", "\"2015-03-05T23:51:47Z\"", "[2015,2,5,23,51,47,4,63]"),
        JQCase("strptime(\"%d/%m/%Y\") | mktime", "\"15/01/2023\"", "1673740800")
    ]
}
