Dynamic_Expansion_State :: struct {
    prefix: string;
    prefix_offset: s32;
    prefix_character_lookup: [256] int;
    matches: [..] Expansion_Match;
    matches_table: Table(string, string);
    current_match_index := -1;
    buffer_to_search: *Buffer;
    should_reset: bool;
}

dynamic_expansion_state: Dynamic_Expansion_State;

reset_dynamic_expansion_state :: (using state: *Dynamic_Expansion_State) {
    if prefix {
        free(prefix);
        prefix = "";
    }

    if matches.count {
        for matches  free(it.found_string);
        table_reset(*matches_table);
        array_reset_keeping_memory(*matches);
    }

    prefix_offset = -1;
    current_match_index = -1;
    should_reset = false;
}

#scope_file

Expansion_Match :: struct {
    found_string: string;
    offset: s32;
    distance_to_cursor: int;
}

scan_buffer_for_matches :: (using state: *Dynamic_Expansion_State) {
    buffer := buffer_to_search;

    if prefix.count > buffer.bytes.count || prefix.count == 0  return;

    start_time := get_time();
    defer {
        print("Scan for expansions took % s. Found % expansions.\n", formatFloat(get_time() - start_time, width = 4), matches.count);
    }

    c := buffer.bytes.data;
    end := buffer.bytes.data + buffer.bytes.count;

    while c < end {
        // Scan to the start of a word.
        if !is_expansion_word_char(<<c) {
            c += 1;
            continue;
        }

        p := prefix.data;
        match := true;

        for 0..prefix.count - 1 {
            if p[it] != <<c {
                c += 1;
                match = false;
                break;
            }
            c += 1;
        }

        match_offset := cast(s32) (c - buffer.bytes.data - prefix.count);

        // Scan to the end of the current word.
        while c < end && is_expansion_word_char(<<c)  c += 1;

        if match && match_offset != prefix_offset {
            word_range := Offset_Range.{ start = match_offset, end = cast(s32) (c - buffer.bytes.data) };
            word := get_range_as_string(buffer, word_range);

            if !table_contains(*matches_table, word) {
                word_copy := copy_string(word);

                table_add(*matches_table, word_copy, word_copy);

                array_add(*matches, .{
                    found_string = word_copy,
                    offset = match_offset,
                    distance_to_cursor = abs(match_offset - prefix_offset),
                });
            }
        }
    }

    compare_distance_to_cursor :: (e1: Expansion_Match, e2: Expansion_Match) -> int {
        return e1.distance_to_cursor - e2.distance_to_cursor;
    }

    quick_sort(matches, compare_distance_to_cursor);
}

#scope_export

try_expand_current_word :: (editor: *Editor, buffer: *Buffer) -> bool {
    state := *dynamic_expansion_state;

    // @TODO: What to do for multiple cursors?
    cursor := editor.cursors.data;

    if !state.prefix {
        if has_selection(cursor) || cursor.pos == 0  return false;
        if !is_expansion_word_char(get_char_at_offset(buffer, cursor.pos - 1))  return false;

        reset_dynamic_expansion_state(state);

        word_end := cursor.pos;
        word_start := cursor.pos - 1;

        while true {
            if word_start == 0 || !is_expansion_word_char(get_char_at_offset(buffer, word_start))  break;
            word_start -= 1;
        }

        word_start += 1;

        state.prefix_offset = word_start;
        state.prefix        = copy_string(get_range_as_string(buffer, .{ start = word_start, end = word_end }));
        state.buffer_to_search = buffer;

        assert(state.prefix.count > 0);

        // memset(state.prefix_character_lookup.data, 0, state.prefix_character_lookup.count);
        // for 0..state.prefix.count - 1  state.prefix_character_lookup[cast(int) state.prefix[it]] = true;

        for 0..state.prefix_character_lookup.count - 1  state.prefix_character_lookup[it] = - 1;
        for 0..state.prefix.count - 1  state.prefix_character_lookup[cast(int) state.prefix[it]] = it;

        scan_buffer_for_matches(state);

        // print("Found % matches for expansion:\n", state.matches.count);
        // for state.matches  print("[%] % (offset = %)\n", it_index, it.found_string, it.offset);
    }

    state.should_reset = false;

    if state.matches.count {
        state.current_match_index += 1;
        if state.current_match_index == state.matches.count  state.current_match_index = -1;
    }

    assert(state.current_match_index >= -1 && state.current_match_index <= state.matches.count);

    expansion := ifx state.current_match_index == -1 then state.prefix else state.matches[state.current_match_index].found_string;

    range_to_replace := Offset_Range.{ start = state.prefix_offset, end = cursor.pos };
    replace_range(buffer, range_to_replace, expansion);

    cursor.pos = state.prefix_offset + cast(s32) expansion.count;
    cursor.sel = cursor.pos;
    put_cursor_in_valid_spot(cursor, buffer);

    organise_cursors(editor);
    editor.cursor_moved = true;

    return true;
}

is_expansion_word_char :: (ch: u32) -> bool {
    return
        (#char "a" <= ch && ch <= #char "z") ||
        (#char "A" <= ch && ch <= #char "Z") ||
        (ch == #char "_" && context.underscore_is_part_of_word) ||
        (#char "0" <= ch && ch <= #char "9") ||
        ch == #char "#";
}
