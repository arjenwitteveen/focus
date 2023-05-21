Dynamic_Expansion_State :: struct {
    prefix: string;
    word_start : s32 = 0;
    matches: [..] string;
    matches_table: Table(string, string);
    last_selected_match_index := -1;
    search_buffer_before_word: string;
    search_buffer_after_word: string;
}

dynamic_expansion_state: Dynamic_Expansion_State;

#scope_file

is_expansion_word_char :: (ch: u32) -> bool {
    return
        (#char "a" <= ch && ch <= #char "z") ||
        (#char "A" <= ch && ch <= #char "Z") ||
        (ch == #char "_" && context.underscore_is_part_of_word) ||
        (#char "0" <= ch && ch <= #char "9");
}

maybe_add_match :: (using state: *Dynamic_Expansion_State, match: string) -> bool {
    _, found := table_find(*matches_table, match);
    if found  return false;

    s := copy_string(match);
    table_add(*matches_table, s, s);
    array_add(*matches, s);
    return true;
}

search_backward_for_expansion :: (using state: *Dynamic_Expansion_State) -> bool {
    if search_buffer_before_word.count == 0  return false;

    found_match := false;

    while search_buffer_before_word.count {
        // Scan to end of a word.
        while search_buffer_before_word.count && !is_expansion_word_char(search_buffer_before_word.data[search_buffer_before_word.count - 1]) {
            search_buffer_before_word.count -= 1;
        }

        search_index := search_buffer_before_word.count - 1;

        // Scan to start of word.
        while search_index > 0 && is_expansion_word_char(search_buffer_before_word[search_index]) {
            search_index -= 1;
        }

        word_length := search_buffer_before_word.count - search_index - 1;
        word := search_buffer_before_word;
        word.data += search_index + 1;
        word.count = word_length;

        if starts_with(word, prefix) && word_length > prefix.count {
            found_match = maybe_add_match(state, word);
            search_buffer_before_word.count = search_index;
            if found_match  break;
        }

        search_buffer_before_word.count = search_index;
    }

    return found_match;
}

search_forward_for_expansion :: (using state: *Dynamic_Expansion_State) -> bool {
    if search_buffer_after_word.count == 0  return false;

    found_match := false;

    while search_buffer_after_word.count {
        if !is_expansion_word_char(search_buffer_after_word.data[0]) {
            search_buffer_after_word.data += 1;
            search_buffer_after_word.count -= 1;
            continue;
        }

        if starts_with(search_buffer_after_word, prefix) {
            // Scan to end of word.
            word_length := 0;

            while word_length < search_buffer_after_word.count && is_expansion_word_char(search_buffer_after_word[word_length]) {
                word_length += 1;
            }

            if word_length > prefix.count { // Ignore match if it's just the same as the prefix.
                match := search_buffer_after_word;
                match.count = word_length;
                found_match = maybe_add_match(state, match);
                search_buffer_after_word.data += word_length;
                search_buffer_after_word.count -= word_length;
                if found_match  break;
            }
        }

        // Skip over the rest of the current word.
        while search_buffer_after_word.count && is_expansion_word_char(search_buffer_after_word.data[0]) {
            search_buffer_after_word.data += 1;
            search_buffer_after_word.count -= 1;
        }
    }

    return found_match;
}

get_next_expansion :: (using state: *Dynamic_Expansion_State) -> string {
    found_match := search_backward_for_expansion(state);
    if !found_match  found_match = search_forward_for_expansion(state);

    print("Dynamic expansion matches: %\n", matches);
    // print("last_selected_match_index = % / %\n", last_selected_match_index, matches.count - 1);

    if matches.count {
        if last_selected_match_index == matches.count - 1 && !found_match {
            last_selected_match_index = -1;
            return "";
        }

        last_selected_match_index = (last_selected_match_index + 1) % matches.count;
        return matches[last_selected_match_index];
    }

    return "";
}

#scope_export

try_expand_current_word :: (editor: *Editor, buffer: *Buffer) {
    cursor := editor.cursors.data;

    if !dynamic_expansion_state.prefix {
        if has_selection(cursor) || cursor.pos == 0  return;
        if !is_expansion_word_char(get_char_at_offset(buffer, cursor.pos - 1))  return;
("Initializing dynamic_expansion_state.\n");

        reset_dynamic_expansion_state(*dynamic_expansion_state);

        word_end := cursor.pos;
        word_start := cursor.pos - 1;

        while true {
            if word_start == 0 || !is_expansion_word_char(get_char_at_offset(buffer, word_start))  break;
            word_start -= 1;
        }

        word_start += 1;

        dynamic_expansion_state.word_start                = word_start;
        dynamic_expansion_state.prefix                    = copy_string(get_range_as_string(buffer, .{ start = word_start, end = word_end }));
        dynamic_expansion_state.search_buffer_before_word = get_range_as_string(buffer, .{ start = 0, end = word_start });
        dynamic_expansion_state.search_buffer_after_word  = get_range_as_string(buffer, .{ start = word_end, end = xx (buffer.bytes.count - 1) });
    }

    expansion := get_next_expansion(*dynamic_expansion_state);

    if expansion {
        assert(cursor.pos >= dynamic_expansion_state.word_start);
        print("Found expansion '%'.\n", expansion);
    } else {
        expansion = dynamic_expansion_state.prefix;
        print("No further expansions, back to '%'.\n", dynamic_expansion_state.prefix);
    }

    range_to_replace := Offset_Range.{ start = dynamic_expansion_state.word_start, end = cursor.pos };
    replace_range(buffer, range_to_replace, expansion);

    cursor.pos = dynamic_expansion_state.word_start + cast(s32) expansion.count;
    cursor.sel = cursor.pos;
    put_cursor_in_valid_spot(cursor, buffer);

    organise_cursors(editor);
}

reset_dynamic_expansion_state :: (using state: *Dynamic_Expansion_State) {
    free(prefix);
    prefix = "";
    deinit(*matches_table);
    for * matches  free(it);
    array_reset(*matches);
    word_start = -1;
    last_selected_match_index = 0;
    search_buffer_before_word = "";
    search_buffer_after_word = "";
}
