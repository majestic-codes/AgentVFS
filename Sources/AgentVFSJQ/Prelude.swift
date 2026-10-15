//
//  Prelude.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Foundation

/// The part of jq's standard library that is written in jq, adapted from jq 1.7's builtin.jq.
enum Prelude {
    static let source = #"""
    def values: select(. != null);
    def nulls: select(. == null);
    def booleans: select(type == "boolean");
    def numbers: select(type == "number");
    def strings: select(type == "string");
    def arrays: select(type == "array");
    def objects: select(type == "object");
    def iterables: select(type|. == "array" or . == "object");
    def scalars: select(type|. != "array" and . != "object");
    def finites: select(isinfinite or isnan | not);
    def isfinite: type == "number" and (isinfinite | not);
    def normals: select(isnormal);
    def select(f): if f then . else empty end;
    def map(f): [.[] | f];
    def map_values(f): .[] |= f;
    def recurse_down: recurse;
    def add(f): reduce f as $x (null; . + $x);
    def any: reduce .[] as $x (false; . or $x);
    def all: reduce .[] as $x (true; . and $x);
    def any(f): reduce (.[] | f) as $x (false; . or $x);
    def all(f): reduce (.[] | f) as $x (true; . and $x);
    def any(generator; condition): isempty(first(generator | condition or empty)) | not;
    def all(generator; condition): isempty(first(generator | condition and empty));
    def in(xs): . as $x | xs | has($x);
    def inside(xs): . as $x | xs | contains($x);
    def del(f): delpaths([path(f)]);
    def paths: path(..) | select(length > 0);
    def paths(node_filter): . as $dot | paths | select(. as $p | $dot | getpath($p) | node_filter);
    def leaf_paths: paths(scalars);
    def pick(pathexps): . as $top | reduce path(pathexps) as $p (null; setpath($p; $top | getpath($p)));
    def with_entries(f): to_entries | map(f) | from_entries;
    def ascii: [.] | implode;
    def todateiso8601: strftime("%Y-%m-%dT%H:%M:%SZ");
    def fromdateiso8601: strptime("%Y-%m-%dT%H:%M:%SZ") | mktime;
    def todate: todateiso8601;
    def fromdate: fromdateiso8601;
    def date: todate;
    def dateadd(u; n): . + n;
    def datesub(u; n): . - n;
    def datesub(u): . - u;
    def env: $ENV;
    def halt_error: halt_error(5);
    def first: .[0];
    def last: .[-1];
    def nth($n): .[$n];
    def nth($n; f): if $n < 0 then error("Out of bounds negative array index") else last(limit($n + 1; f)) end;
    def combinations: if length == 0 then [] else .[0][] as $x | (.[1:] | combinations) as $w | [$x] + $w end;
    def combinations(n): . as $dot | [range(n)] | map($dot) | combinations;
    def walk(f): def w: if type == "object" then map_values(w) elif type == "array" then map(w) else . end | f; w;
    def transpose: if . == [] then [] else . as $in | (map(length) | max) as $max
        | [range(0; $max) as $j | [range(0; $in | length) as $i | $in[$i][$j]]] end;
    def indices($i): if type == "array" and ($i | type) == "array" then .[$i]
        elif type == "array" then .[[$i]]
        elif type == "string" and ($i | type) == "string" then _strindices($i)
        else .[$i] end;
    def index($i): indices($i) | .[0];
    def rindex($i): indices($i) | .[-1:][0];
    def IN(s): any(s == .; .);
    def IN(src; s): any(src == s; .);
    def INDEX(stream; idx_expr): reduce stream as $row ({}; .[$row | idx_expr | tostring] |= $row);
    def INDEX(idx_expr): INDEX(.[]; idx_expr);
    def JOIN($idx; idx_expr): [.[] | [., $idx[idx_expr]]];
    def JOIN($idx; stream; idx_expr): stream | [., $idx[idx_expr]];
    def JOIN($idx; stream; idx_expr; join_expr): stream | [., $idx[idx_expr]] | join_expr;
    def bsearch($target):
        if length == 0 then -1
        elif length == 1 then (if $target == .[0] then 0 elif $target < .[0] then -1 else -2 end)
        else . as $in
            | [0, length - 1, null]
            | until(.[0] > .[1];
                if .[2] != null then .[1] = -1
                else ((.[1] + .[0]) / 2 | floor) as $mid
                    | $in[$mid] as $middle
                    | if $middle == $target then .[2] = $mid
                      elif .[0] == .[1] then .[1] = -1
                      elif $middle < $target then .[0] = $mid + 1
                      else .[1] = $mid - 1 end
                end)
            | if .[2] == null then (if $in[.[0]] < $target then -2 - .[0] else -1 - .[0] end)
              else .[2] end
        end;
    def fromstream(f): { x: null, e: false } as $init
        | foreach f as $i ($init;
            if .e then $init else . end
            | if $i | length == 2
              then setpath(["e"]; $i[0] | length == 0) | setpath(["x"] + $i[0]; $i[1])
              else setpath(["e"]; $i[0] | length == 1) end;
            if .e then .x else empty end);
    def truncate_stream(stream): . as $n | null | stream | . as $input
        | if (.[0] | length) > $n then setpath([0]; .[0][$n:]) else empty end;
    def debug(msg): (msg | debug | empty), .;
    def abs: if type == "number" and . < 0 then -. else . end;
    def toarray: if type == "array" then . else [.] end;
    def _nwise($n): def n: if length <= $n then . else .[0:$n], (.[$n:] | n) end; n;
    def splits($re): splits($re; null);
    def splits($re; flags): split($re; flags) | .[];
    def split($re; flags): . as $s
        | [match($re; "g" + (flags // "")) | (.offset, .offset + .length)] as $ms
        | [0] + $ms + [$s | length] | [_nwise(2)] | map($s[.[0]:.[1]]);
    def match(re; mode): _match_impl(re; mode; false) | .[];
    def match($val): ($val | type) as $vt
        | if $vt == "string" then match($val; null)
          elif $vt == "array" and ($val | length) > 1 then match($val[0]; $val[1])
          elif $vt == "array" and ($val | length) > 0 then match($val[0]; null)
          else error($vt + " not a string or array") end;
    def test(re; mode): _match_impl(re; mode; true);
    def test($val): ($val | type) as $vt
        | if $vt == "string" then test($val; null)
          elif $vt == "array" and ($val | length) > 1 then test($val[0]; $val[1])
          elif $vt == "array" and ($val | length) > 0 then test($val[0]; null)
          else error($vt + " not a string or array") end;
    def capture(re; mods): match(re; mods)
        | reduce (.captures | .[] | select(.name != null) | { key: .name, value: .string }) as $pair
            ({}; . + {($pair.key): $pair.value});
    def capture($val): ($val | type) as $vt
        | if $vt == "string" then capture($val; null)
          elif $vt == "array" and ($val | length) > 1 then capture($val[0]; $val[1])
          elif $vt == "array" and ($val | length) > 0 then capture($val[0]; null)
          else error($vt + " not a string or array") end;
    def scan($re; $flags): match($re; "g" + ($flags // ""))
        | if (.captures | length > 0) then [.captures | .[] | .string] else .string end;
    def scan($re): scan($re; null);
    def sub($re; str; $flags): . as $in
        | (reduce match($re; $flags) as $edit ({result: [], previous: 0};
            $in[.previous: ($edit | .offset)] as $gap
            | [reduce ($edit | .captures | .[] | select(.name != null) | { key: .name, value: .string }) as $pair
                ({}; . + {($pair.key): $pair.value}) | str] as $inserts
            | reduce range(0; $inserts | length) as $ix (.; .result[$ix] += $gap + $inserts[$ix])
            | .previous = ($edit | .offset + .length))
          | .result[] + $in[.previous:])
        // $in;
    def sub($re; str): sub($re; str; "");
    def gsub($re; str; $flags): sub($re; str; $flags + "g");
    def gsub($re; str): sub($re; str; "g");
    """#

    static let definitions: [FunctionDefinition] = {
        do {
            return try Parser.parseDefinitions(source)
        } catch {
            fatalError("jq builtin library does not parse: \(error)")
        }
    }()

    static let table: [String: FunctionDefinition] = Dictionary(definitions.map { ($0.key, $0) }) { $1 }
}
