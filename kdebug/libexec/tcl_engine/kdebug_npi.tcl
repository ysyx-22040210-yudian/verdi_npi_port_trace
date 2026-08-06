set ::kdebug_npi_script_dir [file dirname [file normalize [info script]]]

proc json_escape {s} {
    set out ""
    set n [string length $s]
    for {set i 0} {$i < $n} {incr i} {
        set c [string index $s $i]
        scan $c %c code
        switch -- $c {
            "\"" {append out "\\\""}
            "\\" {append out "\\\\"}
            "\b" {append out "\\b"}
            "\f" {append out "\\f"}
            "\n" {append out "\\n"}
            "\r" {append out "\\r"}
            "\t" {append out "\\t"}
            default {
                if {$code < 32} {
                    append out [format "\\u%04x" $code]
                } else {
                    append out $c
                }
            }
        }
    }
    return $out
}

proc json_string {s} {
    return "\"[json_escape $s]\""
}

proc json_value {v} {
    if {$v eq "__JSON_NULL__"} {return "null"}
    if {$v eq "__JSON_TRUE__"} {return "true"}
    if {$v eq "__JSON_FALSE__"} {return "false"}
    if {[string is integer -strict $v] || [string is double -strict $v]} {return $v}
    return [json_string $v]
}

proc json_array {items} {
    set out {[}
    set first 1
    foreach item $items {
        if {!$first} {append out ","}
        set first 0
        append out [json_value $item]
    }
    append out {]}
    return $out
}

proc json_array_raw {items} {
    set out {[}
    set first 1
    foreach item $items {
        if {!$first} {append out ","}
        set first 0
        append out $item
    }
    append out {]}
    return $out
}

proc json_object {pairs} {
    set out "{"
    set first 1
    foreach {k v} $pairs {
        if {!$first} {append out ","}
        set first 0
        append out [json_string $k] ":"
        append out [json_value $v]
    }
    append out "}"
    return $out
}

proc json_object_raw {pairs} {
    set out "{"
    set first 1
    foreach {k v} $pairs {
        if {!$first} {append out ","}
        set first 0
        append out [json_string $k] ":"
        append out $v
    }
    append out "}"
    return $out
}

proc write_response_raw {json_text} {
    if {![info exists ::env(KDEBUG_TCL_RESPONSE_JSON)] || $::env(KDEBUG_TCL_RESPONSE_JSON) eq ""} {
        puts $json_text
        return
    }
    set fp [open $::env(KDEBUG_TCL_RESPONSE_JSON) w]
    puts $fp $json_text
    close $fp
}

proc ok_data {pairs} {
    write_response_raw [json_object_raw [list ok true data [json_object_raw $pairs]]]
}

proc fail_data {code message} {
    write_response_raw [json_object_raw [list ok false error [json_object [list code $code message $message]]]]
}

proc env_or_empty {name} {
    if {[info exists ::env($name)]} {return $::env($name)}
    return ""
}

proc source_l1 {} {
    if {[info exists ::env(NPIL1_PATH)] && [file exists "$::env(NPIL1_PATH)/npi_L1.tcl"]} {
        source "$::env(NPIL1_PATH)/npi_L1.tcl"
        return
    }
    if {[info exists ::env(VERDI_HOME)] && [file exists "$::env(VERDI_HOME)/share/NPI/L1/TCL/npi_L1.tcl"]} {
        source "$::env(VERDI_HOME)/share/NPI/L1/TCL/npi_L1.tcl"
        return
    }
    error "cannot locate npi_L1.tcl; set VERDI_HOME or NPIL1_PATH"
}

proc import_elab_if_requested {} {
    set elab [env_or_empty KDEBUG_TCL_ELAB]
    if {$elab eq ""} {return 1}
    if {![file exists $elab]} {
        fail_data "KDB_NOT_FOUND" "kdb.elab++ path does not exist: $elab"
        return 0
    }
    if {![file isdirectory $elab]} {
        fail_data "INVALID_KDB_PATH" "kdb.elab++ must be a directory: $elab"
        return 0
    }
    if {[catch {debImport -elab $elab} err]} {
        fail_data "ELAB_IMPORT_FAILED" "debImport -elab failed for $elab: $err"
        return 0
    }
    return 1
}

proc safe_get_str {hdl prop} {
    if {$hdl eq ""} {return ""}
    if {[catch {npi_get_str -property $prop -object $hdl} v]} {return ""}
    return $v
}

proc safe_get {hdl prop} {
    if {$hdl eq ""} {return ""}
    if {[catch {npi_get -property $prop -object $hdl} v]} {return ""}
    return $v
}

proc safe_expr_decompile {hdl} {
    if {$hdl eq ""} {return ""}
    if {[llength [info commands ::npi_L1::npi_expr_decompile]]} {
        if {![catch {::npi_L1::npi_expr_decompile $hdl} v]} {return $v}
    }
    if {[llength [info commands npi_expr_decompile]]} {
        if {![catch {npi_expr_decompile -object $hdl} v]} {return $v}
    }
    return ""
}

proc handle_json {hdl} {
    set pairs [list \
        handle $hdl \
        name [safe_get_str $hdl npiName] \
        full_name [safe_get_str $hdl npiFullName] \
        type [safe_get_str $hdl npiType] \
        file [safe_get_str $hdl npiFile] \
        line [safe_get $hdl npiLineNo] \
        decompiled [safe_expr_decompile $hdl]]
    return [json_object $pairs]
}

proc safe_language_get {hdl prop} {
    if {$hdl eq ""} {return "__JSON_NULL__"}
    if {[catch {npi_get -property $prop -object $hdl} value]} {return "__JSON_NULL__"}
    if {$value eq ""} {return "__JSON_NULL__"}
    return $value
}

proc safe_language_value {hdl format} {
    if {$hdl eq ""} {return "__JSON_NULL__"}
    if {[catch {npi_get_value -format $format -object $hdl} value]} {return "__JSON_NULL__"}
    if {$value eq "NPI_GET_VALUE_ERROR_STR"} {return "__JSON_NULL__"}
    return $value
}

proc language_basic_json {hdl {parent_module ""}} {
    set object_name [safe_get_str $hdl npiName]
    set full_name [safe_get_str $hdl npiFullName]
    if {$full_name eq "" && $parent_module ne "" && $object_name ne ""} {
        set full_name "$parent_module.$object_name"
    }
    return [json_object_raw [list \
        handle [json_string $hdl] \
        name [json_string $object_name] \
        full_name [json_string $full_name] \
        parent_module [json_string $parent_module] \
        type [json_string [safe_get_str $hdl npiType]] \
        def_name [json_string [safe_get_str $hdl npiDefName]] \
        file [json_string [safe_get_str $hdl npiFile]] \
        def_file [json_string [safe_get_str $hdl npiDefFile]] \
        line [json_value [safe_language_get $hdl npiLineNo]] \
        def_line [json_value [safe_language_get $hdl npiDefLineNo]] \
        size [json_value [safe_language_get $hdl npiSize]] \
        direction [json_string [safe_get_str $hdl npiDirection]] \
        port_index [json_value [safe_language_get $hdl npiPortIndex]] \
        port_type [json_string [safe_get_str $hdl npiPortType]] \
        const_type [json_string [safe_get_str $hdl npiConstType]] \
        net_type [json_string [safe_get_str $hdl npiNetType]] \
        local_param [json_value [safe_language_get $hdl npiLocalParam]] \
        signed [json_value [safe_language_get $hdl npiSigned]] \
        automatic [json_value [safe_language_get $hdl npiAutomatic]] \
        top [json_value [safe_language_get $hdl npiTop]] \
        cell_instance [json_value [safe_language_get $hdl npiCellInstance]] \
        decompiled [json_string [safe_expr_decompile $hdl]]]]
}

proc language_values_json {hdl} {
    set pairs {}
    foreach {name format} {
        bin npiBinStrVal
        oct npiOctStrVal
        hex npiHexStrVal
        dec npiDecStrVal
        string npiStringVal
        real npiRealVal
        int npiIntVal
    } {
        set value [safe_language_value $hdl $format]
        if {$value eq "__JSON_NULL__"} {
            lappend pairs $name null
        } else {
            lappend pairs $name [json_string $value]
        }
    }
    return [json_object_raw $pairs]
}

proc language_relation_json {hdl relation_type} {
    if {[catch {npi_handle -type $relation_type -refHandle $hdl} related] || $related eq ""} {
        return "null"
    }
    set result [language_basic_json $related]
    catch {npi_release_handle -object $related}
    return $result
}

proc language_object_json {hdl include_value include_connections {parent_module ""}} {
    set basic [language_basic_json $hdl $parent_module]
    set pairs [list object $basic]
    if {$include_value} {
        lappend pairs values [language_values_json $hdl]
    }
    if {$include_connections} {
        lappend pairs connections [json_object_raw [list \
            high [language_relation_json $hdl npiHighConn] \
            low [language_relation_json $hdl npiLowConn]]]
    }
    return [json_object_raw $pairs]
}

proc resolve_language_handle {name scope} {
    if {$scope eq ""} {
        return [npi_handle_by_name -name $name -scope ""]
    }
    return [npi_handle_by_name -name $name -scope $scope]
}

proc resolve_module_port_handle {name scope} {
    set full_name $name
    if {$scope ne "" && [string first "." $name] < 0} {
        set full_name "$scope.$name"
    }
    if {![regexp {^(.+)\.([^.]+)$} $full_name -> module_name port_name]} {
        return ""
    }
    set command ::npi_L1::npi_mod_inst_get_port
    if {![command_available $command]} {return ""}
    set handles {}
    if {[catch [list $command $module_name handles] count] || $count <= 0} {
        return ""
    }
    set matched ""
    foreach hdl $handles {
        if {$matched eq "" && [safe_get_str $hdl npiName] eq $port_name} {
            set matched $hdl
        } else {
            catch {npi_release_handle -object $hdl}
        }
    }
    return $matched
}

proc language_resolve_action {name scope} {
    if {$name eq ""} {
        fail_data "MISSING_FIELD" "args.name is required"
        return
    }
    foreach command {npi_handle_by_name npi_get npi_get_str npi_get_value} {
        if {![require_command $command]} {return}
    }
    set hdl [resolve_language_handle $name $scope]
    if {$hdl eq ""} {
        fail_data "LANGUAGE_OBJECT_NOT_FOUND" "language object not found: $name"
        return
    }
    set object [language_object_json $hdl 1 1]
    catch {npi_release_handle -object $hdl}
    ok_data [list \
        query [json_string $name] \
        scope [json_string $scope] \
        object $object \
        summary [json_object [list name $name scope $scope status resolved]]]
}

proc language_iterate_action {name scope object_type max_rows} {
    if {$name eq "" || $object_type eq ""} {
        fail_data "MISSING_FIELD" "args.name and args.object_type are required"
        return
    }
    if {![valid_npi_enum $object_type npi]} {
        fail_data "INVALID_ENUM" "args.object_type must be an npi* enum"
        return
    }
    foreach command {npi_handle_by_name npi_iterate npi_scan} {
        if {![require_command $command]} {return}
    }
    set ref [resolve_language_handle $name $scope]
    if {$ref eq ""} {
        fail_data "LANGUAGE_OBJECT_NOT_FOUND" "language reference object not found: $name"
        return
    }
    set iter [npi_iterate -type $object_type -refHandle $ref]
    set rows {}
    set limit [positive_limit $max_rows 200]
    set truncated 0
    if {$iter ne ""} {
        while {1} {
            set child [npi_scan -iterator $iter]
            if {$child eq ""} {break}
            if {[llength $rows] >= $limit} {
                set truncated 1
                catch {npi_release_handle -object $child}
                break
            }
            lappend rows [language_object_json $child 1 [expr {$object_type eq "npiPort"}]]
            catch {npi_release_handle -object $child}
        }
    }
    if {$truncated && $iter ne ""} {catch {npi_release_handle -object $iter}}
    catch {npi_release_handle -object $ref}
    ok_data [list \
        reference [json_string $name] \
        scope [json_string $scope] \
        object_type [json_string $object_type] \
        count [llength $rows] \
        truncated [json_value [expr {$truncated ? "__JSON_TRUE__" : "__JSON_FALSE__"}]] \
        items [json_array_raw $rows] \
        summary [json_object [list reference $name object_type $object_type count [llength $rows] truncated [expr {$truncated ? "__JSON_TRUE__" : "__JSON_FALSE__"}]]]]
}

proc language_relate_action {name scope relation_type} {
    if {$name eq "" || $relation_type eq ""} {
        fail_data "MISSING_FIELD" "args.name and args.relation_type are required"
        return
    }
    if {![valid_npi_enum $relation_type npi]} {
        fail_data "INVALID_ENUM" "args.relation_type must be an npi* enum"
        return
    }
    foreach command {npi_handle_by_name npi_handle} {
        if {![require_command $command]} {return}
    }
    set ref [resolve_language_handle $name $scope]
    if {$ref eq ""} {
        fail_data "LANGUAGE_OBJECT_NOT_FOUND" "language source object not found: $name"
        return
    }
    set related [npi_handle -type $relation_type -refHandle $ref]
    if {$related eq "" && $relation_type in {npiHighConn npiLowConn}} {
        catch {npi_release_handle -object $ref}
        set ref [resolve_module_port_handle $name $scope]
        if {$ref ne ""} {
            set related [npi_handle -type $relation_type -refHandle $ref]
        }
    }
    if {$related eq ""} {
        if {$ref ne ""} {catch {npi_release_handle -object $ref}}
        fail_data "LANGUAGE_RELATION_NOT_FOUND" "relationship $relation_type is not available for $name"
        return
    }
    set object [language_object_json $related 1 [expr {$relation_type in {npiPort npiHighConn npiLowConn}}]]
    catch {npi_release_handle -object $related}
    catch {npi_release_handle -object $ref}
    ok_data [list \
        source [json_string $name] \
        relation_type [json_string $relation_type] \
        object $object \
        summary [json_object [list source $name relation_type $relation_type status resolved]]]
}

proc language_value_action {name scope format} {
    if {$name eq ""} {
        fail_data "MISSING_FIELD" "args.name is required"
        return
    }
    if {$format eq ""} {set format npiHexStrVal}
    if {$format ni {npiBinStrVal npiOctStrVal npiHexStrVal npiDecStrVal npiStringVal npiRealVal npiIntVal}} {
        fail_data "INVALID_ENUM" "args.format is not a supported NPI value format"
        return
    }
    foreach command {npi_handle_by_name npi_get_value} {
        if {![require_command $command]} {return}
    }
    set hdl [resolve_language_handle $name $scope]
    if {$hdl eq ""} {
        fail_data "LANGUAGE_OBJECT_NOT_FOUND" "language object not found: $name"
        return
    }
    set value [safe_language_value $hdl $format]
    if {$value eq "__JSON_NULL__"} {
        catch {npi_release_handle -object $hdl}
        fail_data "VALUE_UNAVAILABLE" "object does not support $format: $name"
        return
    }
    set size [safe_language_get $hdl npiSize]
    set signed [safe_language_get $hdl npiSigned]
    set type [safe_get_str $hdl npiType]
    catch {npi_release_handle -object $hdl}
    ok_data [list \
        name [json_string $name] \
        type [json_string $type] \
        format [json_string $format] \
        value [json_string $value] \
        size [json_value $size] \
        signed [json_value $signed] \
        summary [json_object [list name $name format $format status ok]]]
}

proc module_kind_command {kind} {
    switch -- $kind {
        continuous_assignments {return ::npi_L1::npi_mod_inst_get_cont_assign}
        functions {return ::npi_L1::npi_mod_inst_get_func}
        generate_scopes {return ::npi_L1::npi_mod_inst_get_gen_scope}
        instances {return ::npi_L1::npi_mod_inst_get_instance}
        instances_in_generate {return ::npi_L1::npi_mod_inst_get_instance_in_gen_scope}
        io {return ::npi_L1::npi_mod_inst_get_io}
        language_interfaces {return ::npi_L1::npi_mod_inst_get_lang_interface}
        nets {return ::npi_L1::npi_mod_inst_get_net}
        parameters {return ::npi_L1::npi_mod_inst_get_parameter}
        ports {return ::npi_L1::npi_mod_inst_get_port}
        primitives {return ::npi_L1::npi_mod_inst_get_primitive}
        always_processes {return ::npi_L1::npi_mod_inst_get_process_always}
        initial_processes {return ::npi_L1::npi_mod_inst_get_process_init}
        tasks {return ::npi_L1::npi_mod_inst_get_task}
        variables {return ::npi_L1::npi_mod_inst_get_var}
        default {return ""}
    }
}

proc module_section_json {module kind max_rows total_var returned_var truncated_var error_var} {
    upvar 1 $total_var total
    upvar 1 $returned_var returned
    upvar 1 $truncated_var truncated
    upvar 1 $error_var error_message
    set total 0
    set returned 0
    set truncated 0
    set error_message ""
    set command [module_kind_command $kind]
    if {$command eq ""} {
        set error_message "unsupported module object kind: $kind"
        return "[]"
    }
    if {![command_available $command]} {
        set error_message "NPI command is unavailable in this Verdi runtime: $command"
        return "[]"
    }
    set handles {}
    if {[catch [list $command $module handles] total]} {
        set error_message "module query failed for $kind: $total"
        set total 0
        return "[]"
    }
    set limit [positive_limit $max_rows 200]
    set rows {}
    set index 0
    foreach hdl $handles {
        if {$index < $limit} {
            set include_value [expr {$kind eq "parameters"}]
            set include_connections [expr {$kind eq "ports"}]
            lappend rows [language_object_json $hdl $include_value $include_connections $module]
            incr returned
        } else {
            set truncated 1
        }
        incr index
        catch {npi_release_handle -object $hdl}
    }
    if {$total > $returned} {set truncated 1}
    return [json_array_raw $rows]
}

proc require_module_object {module} {
    if {$module eq ""} {
        fail_data "MISSING_FIELD" "args.module is required"
        return ""
    }
    if {![require_command npi_handle_by_name]} {return ""}
    set hdl [resolve_language_handle $module ""]
    if {$hdl eq ""} {
        fail_data "MODULE_NOT_FOUND" "module instance not found: $module"
        return ""
    }
    return $hdl
}

proc module_objects_action {module kind max_rows} {
    if {$kind eq ""} {
        fail_data "MISSING_FIELD" "args.kind is required"
        return
    }
    set module_hdl [require_module_object $module]
    if {$module_hdl eq ""} {return}
    set items [module_section_json $module $kind $max_rows total returned truncated error_message]
    catch {npi_release_handle -object $module_hdl}
    if {$error_message ne ""} {
        fail_data "MODULE_QUERY_FAILED" $error_message
        return
    }
    ok_data [list \
        module [json_string $module] \
        kind [json_string $kind] \
        count $total \
        returned_count $returned \
        truncated [json_value [expr {$truncated ? "__JSON_TRUE__" : "__JSON_FALSE__"}]] \
        items $items \
        summary [json_object [list module $module kind $kind count $total returned_count $returned truncated [expr {$truncated ? "__JSON_TRUE__" : "__JSON_FALSE__"}]]]]
}

proc module_find_instances_action {definition max_rows} {
    if {$definition eq ""} {
        fail_data "MISSING_FIELD" "args.definition is required"
        return
    }
    set command ::npi_L1::npi_mod_define_get_inst
    if {![command_available $command]} {
        fail_data "NPI_COMMAND_UNAVAILABLE" "NPI command is unavailable in this Verdi runtime: $command"
        return
    }
    set handles {}
    if {[catch [list $command $definition handles] total]} {
        fail_data "MODULE_QUERY_FAILED" "module definition query failed: $total"
        return
    }
    set limit [positive_limit $max_rows 200]
    set rows {}
    set returned 0
    set truncated 0
    foreach hdl $handles {
        if {$returned < $limit} {
            lappend rows [language_object_json $hdl 0 0]
            incr returned
        } else {
            set truncated 1
        }
        catch {npi_release_handle -object $hdl}
    }
    if {$total > $returned} {set truncated 1}
    ok_data [list \
        definition [json_string $definition] \
        count $total \
        returned_count $returned \
        truncated [json_value [expr {$truncated ? "__JSON_TRUE__" : "__JSON_FALSE__"}]] \
        instances [json_array_raw $rows] \
        summary [json_object [list definition $definition count $total returned_count $returned truncated [expr {$truncated ? "__JSON_TRUE__" : "__JSON_FALSE__"}]]]]
}

proc module_inspect_result {module sections_text max_rows} {
    if {$module eq ""} {
        return [list 0 "" MISSING_FIELD "args.module is required" 0]
    }
    if {![command_available npi_handle_by_name]} {
        return [list 0 "" NPI_COMMAND_UNAVAILABLE "NPI command is unavailable in this Verdi runtime: npi_handle_by_name" 0]
    }
    if {[catch {set module_hdl [resolve_language_handle $module ""]} resolve_error]} {
        return [list 0 "" MODULE_QUERY_FAILED "module instance lookup failed: $resolve_error" 0]
    }
    if {$module_hdl eq ""} {
        return [list 0 "" MODULE_NOT_FOUND "module instance not found: $module" 0]
    }
    if {$sections_text eq ""} {
        set sections {instances parameters ports io nets variables generate_scopes}
    } else {
        set sections [split $sections_text "\n"]
    }
    set section_pairs {}
    set count_pairs {}
    set returned_pairs {}
    set any_truncated 0
    foreach kind $sections {
        if {$kind eq ""} {continue}
        set items [module_section_json $module $kind $max_rows total returned truncated error_message]
        if {$error_message ne ""} {
            catch {npi_release_handle -object $module_hdl}
            return [list 0 "" MODULE_QUERY_FAILED $error_message 0]
        }
        lappend section_pairs $kind $items
        lappend count_pairs $kind [json_value $total]
        lappend returned_pairs $kind [json_value $returned]
        if {$truncated} {set any_truncated 1}
    }
    set module_object [language_object_json $module_hdl 0 0]
    catch {npi_release_handle -object $module_hdl}
    set data [json_object_raw [list \
        module [json_string $module] \
        module_object $module_object \
        sections [json_object_raw $section_pairs] \
        counts [json_object_raw $count_pairs] \
        returned_counts [json_object_raw $returned_pairs] \
        truncated [json_value [expr {$any_truncated ? "__JSON_TRUE__" : "__JSON_FALSE__"}]] \
        summary [json_object_raw [list module [json_string $module] section_count [json_value [llength $sections]] truncated [json_value [expr {$any_truncated ? "__JSON_TRUE__" : "__JSON_FALSE__"}]] counts [json_object_raw $count_pairs]]]]]
    return [list 1 $data "" "" $any_truncated]
}

proc module_inspect_action {module sections_text max_rows} {
    lassign [module_inspect_result $module $sections_text $max_rows] succeeded data code message truncated
    if {!$succeeded} {
        fail_data $code $message
        return
    }
    write_response_raw [json_object_raw [list ok true data $data]]
}

proc module_inspect_batch_action {plan sections_text max_rows} {
    if {[catch {set rows [read_plan_rows $plan 1]} plan_error]} {
        fail_data "INVALID_PLAN" $plan_error
        return
    }
    if {[llength $rows] == 0} {
        fail_data "MISSING_FIELD" "args.modules must be a non-empty array"
        return
    }
    set inspections {}
    set success_count 0
    set error_count 0
    set any_truncated 0
    foreach row $rows {
        if {[catch {set module [decode_hex_utf8 [lindex $row 0]]} decode_error]} {
            fail_data "INVALID_PLAN" $decode_error
            return
        }
        lassign [module_inspect_result $module $sections_text $max_rows] succeeded data code message truncated
        if {$succeeded} {
            incr success_count
            if {$truncated} {set any_truncated 1}
            lappend inspections [json_object_raw [list \
                module [json_string $module] ok true data $data error null]]
        } else {
            incr error_count
            lappend inspections [json_object_raw [list \
                module [json_string $module] ok false data null \
                error [json_object [list code $code message $message]]]]
        }
    }
    ok_data [list \
        inspections [json_array_raw $inspections] \
        truncated [json_value [expr {$any_truncated ? "__JSON_TRUE__" : "__JSON_FALSE__"}]] \
        summary [json_object [list module_count [llength $rows] success_count $success_count error_count $error_count truncated [expr {$any_truncated ? "__JSON_TRUE__" : "__JSON_FALSE__"}]]]]
}

proc trace_result {mode signal max_rows} {
    if {$signal eq ""} {
        return [list 0 "" MISSING_FIELD "args.signal is required" 0 error]
    }
    if {$mode ne "driver" && $mode ne "load"} {
        return [list 0 "" INVALID_ARGUMENT "trace mode must be driver or load" 0 error]
    }
    set handles {}
    if {[catch {
        if {$mode eq "load"} {
            set count [::npi_L1::npi_trace_load $signal handles]
        } else {
            set count [::npi_L1::npi_trace_driver $signal handles]
        }
    } trace_error]} {
        foreach h $handles {catch {npi_release_handle -object $h}}
        return [list 0 "" TRACE_QUERY_FAILED $trace_error 0 error]
    }
    set arr {}
    set limit [positive_limit $max_rows 200]
    set returned 0
    set truncated 0
    foreach h $handles {
        if {$returned < $limit} {
            lappend arr [handle_json $h]
            incr returned
        } else {
            set truncated 1
        }
        catch {npi_release_handle -object $h}
    }
    if {$count > $returned} {set truncated 1}
    set status [expr {$count > 0 ? "ok" : "not_found"}]
    set data [json_object_raw [list \
        signal [json_string $signal] \
        mode [json_string $mode] \
        status [json_string $status] \
        count $count \
        returned_count $returned \
        truncated [json_value [expr {$truncated ? "__JSON_TRUE__" : "__JSON_FALSE__"}]] \
        handles [json_array_raw $arr] \
        summary [json_object [list signal $signal mode $mode count $count returned_count $returned status $status truncated [expr {$truncated ? "__JSON_TRUE__" : "__JSON_FALSE__"}]]]]]
    return [list 1 $data "" "" $truncated $status]
}

proc trace_action {mode signal max_rows} {
    lassign [trace_result $mode $signal $max_rows] succeeded data code message truncated status
    if {!$succeeded} {
        fail_data $code $message
        return
    }
    write_response_raw [json_object_raw [list ok true data $data]]
}

proc port_trace_plan_values {plan required label} {
    set rows [read_plan_rows $plan 1]
    set values {}
    foreach row $rows {
        lappend values [decode_hex_utf8 [lindex $row 0]]
    }
    if {$required && [llength $values] == 0} {
        error "$label must be a non-empty array"
    }
    return $values
}

proc port_trace_dict_value {record key} {
    if {[dict exists $record $key]} {return [dict get $record $key]}
    return ""
}

proc port_trace_row_json {row} {
    return [json_object [list \
        inst_full_name [port_trace_dict_value $row inst_full_name] \
        port_name [port_trace_dict_value $row port_name] \
        port_dir [port_trace_dict_value $row port_dir] \
        role [port_trace_dict_value $row role] \
        signal_full_name [port_trace_dict_value $row signal_full_name]]]
}

proc port_trace_error_json {record} {
    set fields {}
    foreach key {scope code message module instance port signal value handle} {
        if {[dict exists $record $key]} {
            lappend fields $key [dict get $record $key]
        }
    }
    return [json_object $fields]
}

proc port_trace_effective_method {method role} {
    if {$role ne "driver"} {return 0}
    expr {$method in {
        source_port_connection
        npi_connection
        connected_signal_const
        parent_port_connection_const
        parent_port_chain
        parent_port_chain_terminal
        source_const_assign_map
        source_assign_const_chain
        source_assign_direct
        source_assign_driver
        module_port_high_conn
    }}
}

proc port_trace_evidence_json {record} {
    set method [port_trace_dict_value $record method]
    set value [port_trace_dict_value $record value]
    set const_full_path [port_trace_dict_value $record const_full_path]
    set fields [port_trace_dict_value $record fields]
    set role [port_trace_dict_value $fields role]
    set candidate_effective [port_trace_effective_method $method $role]

    set path_items {}
    foreach node [split [string map [list "<-" "\n"] $const_full_path] "\n"] {
        set node [string trim $node]
        if {$node ne ""} {lappend path_items $node}
    }
    set source [json_object [list \
        file [port_trace_dict_value $fields source_file] \
        line [port_trace_dict_value $fields source_line] \
        raw_handle [port_trace_dict_value $fields source_handle_path] \
        raw_handle_kind [port_trace_dict_value $fields source_handle_kind]]]
    set provenance [json_object_raw [list \
        origin [json_string $method] \
        unconditional [expr {$candidate_effective ? "true" : "false"}] \
        path [json_array $path_items] \
        source $source]]
    set constant [json_object_raw [list \
        value [json_string $value] \
        effective [expr {$candidate_effective ? "true" : "false"}]]]
    return [json_object_raw [list \
        kind [json_string constant] \
        value [json_string $value] \
        method [json_string $method] \
        role [json_string $role] \
        port_path [json_string [port_trace_dict_value $fields port_path]] \
        const_full_path [json_string $const_full_path] \
        effective_candidate [expr {$candidate_effective ? "true" : "false"}] \
        constant $constant \
        provenance $provenance \
        fields [json_object $fields]]]
}

proc port_trace_batch_action {
    module port_plan stop_plan source source_fallback include_full include_boundary
    max_parent_depth max_assign_depth max_expr_depth max_nodes max_edges
    max_api_results max_rows debug_enabled
} {
    if {$module eq ""} {
        fail_data "MISSING_FIELD" "args.module is required"
        return
    }
    if {$source ne "" && ![file isfile $source]} {
        fail_data "SOURCE_FILE_NOT_FOUND" "args.source does not exist: $source"
        return
    }
    if {[catch {
        set ports [port_trace_plan_values $port_plan 0 "args.ports"]
        set stop_instances [port_trace_plan_values $stop_plan 0 "args.stop_instances"]
    } plan_error]} {
        fail_data "INVALID_PLAN" $plan_error
        return
    }

    lassign [kdebug_port_trace_run \
        $module $ports $stop_instances $source \
        [bool_value $source_fallback] [bool_value $include_full] [bool_value $include_boundary] \
        $max_parent_depth $max_assign_depth $max_expr_depth $max_nodes $max_edges \
        $max_api_results $max_rows [bool_value $debug_enabled]] \
        succeeded code message processed_instances skipped_instances
    if {!$succeeded} {
        fail_data $code $message
        return
    }

    set full_rows {}
    foreach row $::kdebug_port_trace_full_rows {
        lappend full_rows [port_trace_row_json $row]
    }
    set boundary_rows {}
    foreach row $::kdebug_port_trace_boundary_rows {
        lappend boundary_rows [port_trace_row_json $row]
    }
    set evidence {}
    foreach record $::kdebug_port_trace_evidence {
        lappend evidence [port_trace_evidence_json $record]
    }
    set errors {}
    foreach record $::kdebug_port_trace_errors {
        lappend errors [port_trace_error_json $record]
    }
    set truncated [expr {$::kdebug_port_trace_truncated ? "true" : "false"}]
    set port_trace_response_pairs [list \
        module [json_string $module] \
        requested_ports [json_array $ports] \
        full_rows [json_array_raw $full_rows] \
        boundary_rows [json_array_raw $boundary_rows] \
        evidence [json_array_raw $evidence] \
        errors [json_array_raw $errors] \
        truncated $truncated \
        stats [json_object [list \
            processed_instances $processed_instances \
            skipped_instances $skipped_instances \
            full_row_count [llength $full_rows] \
            boundary_row_count [llength $boundary_rows] \
            evidence_count [llength $evidence] \
            error_count [llength $errors]]] \
        summary [json_object [list \
            module $module \
            port_count [llength $ports] \
            processed_instances $processed_instances \
            full_row_count [llength $full_rows] \
            boundary_row_count [llength $boundary_rows] \
            evidence_count [llength $evidence] \
            error_count [llength $errors] \
            truncated [expr {$::kdebug_port_trace_truncated ? "__JSON_TRUE__" : "__JSON_FALSE__"}]]]]
    if {[catch {llength $port_trace_response_pairs} response_list_error]} {
        fail_data "TCL_RESPONSE_ENCODING_FAILED" $response_list_error
        return
    }
    ok_data $port_trace_response_pairs
}

proc resolve_action {signal} {
    if {$signal eq ""} {
        fail_data "MISSING_FIELD" "args.signal is required"
        return
    }
    set h [npi_handle_by_name -name $signal -scope ""]
    if {$h eq ""} {
        fail_data "SIGNAL_NOT_FOUND" "signal not found: $signal"
        return
    }
    set full [safe_get_str $h npiFullName]
    if {$full eq ""} {set full $signal}
    set data [handle_json $h]
    catch {npi_release_handle -object $h}
    ok_data [list \
        query [json_string $signal] \
        canonical_signal [json_string $full] \
        rtl_path [json_string $full] \
        resolved $data \
        summary [json_object [list query $signal canonical_signal $full]]]
}

proc canonicalize_action {signal} {
    if {$signal eq ""} {
        fail_data "MISSING_FIELD" "args.signal is required"
        return
    }
    set h [npi_handle_by_name -name $signal -scope ""]
    if {$h eq ""} {
        fail_data "SIGNAL_NOT_FOUND" "signal not found: $signal"
        return
    }
    set full [safe_get_str $h npiFullName]
    if {$full eq ""} {set full $signal}
    set leaf [safe_get_str $h npiName]
    catch {npi_release_handle -object $h}
    ok_data [list \
        query [json_string $signal] \
        canonical [json_string $full] \
        rtl_path [json_string $full] \
        leaf [json_string $leaf] \
        ambiguous false \
        aliases [] \
        fsdb_candidates [] \
        port_mappings [] \
        summary [json_object [list query $signal ambiguous __JSON_FALSE__]]]
}

proc fsdb_format {fmt} {
    set f [string tolower $fmt]
    if {$f eq "bin" || $f eq "binary" || $f eq "b"} {return npiFsdbBinStrVal}
    if {$f eq "dec" || $f eq "decimal" || $f eq "d"} {return npiFsdbDecStrVal}
    return npiFsdbHexStrVal
}

proc fsdb_radix_char {fmt} {
    set f [string tolower $fmt]
    if {$f eq "bin" || $f eq "binary" || $f eq "b"} {return "b"}
    if {$f eq "dec" || $f eq "decimal" || $f eq "d"} {return "d"}
    return "h"
}

proc parse_fsdb_time {file_hdl time default_kind out_name} {
    upvar 1 $out_name fsdb_time
    if {$time eq ""} {
        if {$default_kind eq "max"} {
            set fsdb_time [npi_fsdb_max_time -file $file_hdl]
        } else {
            set fsdb_time [npi_fsdb_min_time -file $file_hdl]
        }
        return 1
    }
    if {$time eq "min"} {
        set fsdb_time [npi_fsdb_min_time -file $file_hdl]
        return 1
    }
    if {$time eq "max"} {
        set fsdb_time [npi_fsdb_max_time -file $file_hdl]
        return 1
    }
    if {![regexp {^([0-9]+(?:\.[0-9]+)?)([a-zA-Z]+)$} $time -> tv tu]} {
        return 0
    }
    set converted [::npi_L1::npi_fsdb_convert_time_in $file_hdl $tv $tu]
    if {$converted eq ""} {return 0}
    set fsdb_time $converted
    return 1
}

proc safe_fsdb_sig_prop_str {sig prop} {
    if {$sig eq ""} {return ""}
    if {[catch {npi_fsdb_sig_property_str -sig $sig -type $prop} v]} {return ""}
    return $v
}

proc safe_fsdb_sig_prop {sig prop} {
    if {$sig eq ""} {return ""}
    if {[catch {npi_fsdb_sig_property -sig $sig -type $prop} v]} {return ""}
    return $v
}

proc signal_info_action {fsdb signal} {
    if {$fsdb eq ""} {
        fail_data "RESOURCE_REQUIRED" "target.fsdb is required"
        return
    }
    if {$signal eq ""} {
        fail_data "MISSING_FIELD" "args.signal is required"
        return
    }
    set file_hdl [npi_fsdb_open -name $fsdb]
    if {$file_hdl eq ""} {
        fail_data "FSDB_OPEN_FAILED" "failed to open FSDB: $fsdb"
        return
    }
    set sig_hdl [npi_fsdb_sig_by_name -file $file_hdl -name $signal -scope ""]
    if {$sig_hdl eq ""} {
        catch {npi_fsdb_close -file $file_hdl}
        fail_data "SIGNAL_NOT_FOUND" "signal not found: $signal"
        return
    }
    set full [safe_fsdb_sig_prop_str $sig_hdl npiFsdbSigFullName]
    if {$full eq ""} {set full $signal}
    set name [safe_fsdb_sig_prop_str $sig_hdl npiFsdbSigName]
    set type [safe_fsdb_sig_prop_str $sig_hdl npiFsdbSigType]
    set bit_size [safe_fsdb_sig_prop $sig_hdl npiFsdbSigBitSize]
    set min_time [npi_fsdb_min_time -file $file_hdl]
    set max_time [npi_fsdb_max_time -file $file_hdl]
    set scale_unit [npi_fsdb_file_property_str -file $file_hdl -type npiFsdbFileScaleUnit]
    catch {npi_fsdb_close -file $file_hdl}
    ok_data [list \
        signal [json_string $signal] \
        full_name [json_string $full] \
        name [json_string $name] \
        type [json_string $type] \
        bit_size [json_string $bit_size] \
        min_time $min_time \
        max_time $max_time \
        scale_unit [json_string $scale_unit] \
        summary [json_object [list signal $signal full_name $full]]]
}

proc value_at_action {fsdb signal time fmt} {
    if {$fsdb eq ""} {
        fail_data "RESOURCE_REQUIRED" "target.fsdb is required"
        return
    }
    if {$signal eq "" || $time eq ""} {
        fail_data "MISSING_FIELD" "args.signal and args.time are required"
        return
    }
    set file_hdl [npi_fsdb_open -name $fsdb]
    if {$file_hdl eq ""} {
        fail_data "FSDB_OPEN_FAILED" "failed to open FSDB: $fsdb"
        return
    }
    if {![regexp {^([0-9]+(?:\.[0-9]+)?)([a-zA-Z]+)$} $time -> tv tu]} {
        catch {npi_fsdb_close -file $file_hdl}
        fail_data "TIME_SPEC_INVALID" "failed to parse time: $time"
        return
    }
    set fsdb_time [::npi_L1::npi_fsdb_convert_time_in $file_hdl $tv $tu]
    if {$fsdb_time eq ""} {
        catch {npi_fsdb_close -file $file_hdl}
        fail_data "TIME_SPEC_INVALID" "failed to convert time: $time"
        return
    }
    set format [fsdb_format $fmt]
    set raw [::npi_L1::npi_fsdb_sig_value_at $file_hdl $signal $fsdb_time $format]
    if {$raw eq ""} {
        catch {npi_fsdb_close -file $file_hdl}
        fail_data "SIGNAL_NOT_FOUND" "failed to read value: $signal"
        return
    }
    set radix [fsdb_radix_char $fmt]
    catch {npi_fsdb_close -file $file_hdl}
    ok_data [list \
        signal [json_string $signal] \
        time [json_string $time] \
        fsdb_time $fsdb_time \
        raw [json_string $raw] \
        radix [json_string $radix] \
        status [json_string "ok"] \
        summary [json_object [list signal $signal time $time status ok]]]
}

proc value_batch_at_action {fsdb signals time fmt} {
    if {$fsdb eq ""} {
        fail_data "RESOURCE_REQUIRED" "target.fsdb is required"
        return
    }
    if {[llength $signals] == 0 || $time eq ""} {
        fail_data "MISSING_FIELD" "args.signals[] and args.time are required"
        return
    }
    set file_hdl [npi_fsdb_open -name $fsdb]
    if {$file_hdl eq ""} {
        fail_data "FSDB_OPEN_FAILED" "failed to open FSDB: $fsdb"
        return
    }
    if {![regexp {^([0-9]+(?:\.[0-9]+)?)([a-zA-Z]+)$} $time -> tv tu]} {
        catch {npi_fsdb_close -file $file_hdl}
        fail_data "TIME_SPEC_INVALID" "failed to parse time: $time"
        return
    }
    set fsdb_time [::npi_L1::npi_fsdb_convert_time_in $file_hdl $tv $tu]
    set format [fsdb_format $fmt]
    set radix [fsdb_radix_char $fmt]
    set arr {}
    set missing 0
    foreach sig $signals {
        set raw [::npi_L1::npi_fsdb_sig_value_at $file_hdl $sig $fsdb_time $format]
        if {$raw eq ""} {
            incr missing
            lappend arr [json_object_raw [list signal [json_string $sig] time [json_string $time] status [json_string "signal_not_found"] value null raw null]]
        } else {
            lappend arr [json_object_raw [list signal [json_string $sig] time [json_string $time] status [json_string "ok"] raw [json_string $raw] radix [json_string $radix]]]
        }
    }
    catch {npi_fsdb_close -file $file_hdl}
    ok_data [list \
        time [json_string $time] \
        fsdb_time $fsdb_time \
        values [json_array_raw $arr] \
        summary [json_object [list time $time signal_count [llength $signals] missing_count $missing]]]
}

proc signal_scan_action {fsdb signal begin_time end_time fmt max_rows} {
    if {$fsdb eq ""} {
        fail_data "RESOURCE_REQUIRED" "target.fsdb is required"
        return
    }
    if {$signal eq ""} {
        fail_data "MISSING_FIELD" "args.signal is required"
        return
    }
    set file_hdl [npi_fsdb_open -name $fsdb]
    if {$file_hdl eq ""} {
        fail_data "FSDB_OPEN_FAILED" "failed to open FSDB: $fsdb"
        return
    }
    set sig_hdl [npi_fsdb_sig_by_name -file $file_hdl -name $signal -scope ""]
    if {$sig_hdl eq ""} {
        catch {npi_fsdb_close -file $file_hdl}
        fail_data "SIGNAL_NOT_FOUND" "signal not found: $signal"
        return
    }
    if {![parse_fsdb_time $file_hdl $begin_time min begin_fsdb]} {
        catch {npi_fsdb_close -file $file_hdl}
        fail_data "TIME_SPEC_INVALID" "failed to parse begin time: $begin_time"
        return
    }
    if {![parse_fsdb_time $file_hdl $end_time max end_fsdb]} {
        catch {npi_fsdb_close -file $file_hdl}
        fail_data "TIME_SPEC_INVALID" "failed to parse end time: $end_time"
        return
    }
    if {$max_rows eq "" || $max_rows <= 0} {set max_rows 200}
    set format [fsdb_format $fmt]
    set radix [fsdb_radix_char $fmt]
    set vct_hdl [npi_fsdb_create_vct -sig $sig_hdl]
    if {$vct_hdl eq ""} {
        catch {npi_fsdb_close -file $file_hdl}
        fail_data "VCT_CREATE_FAILED" "failed to create value-change traversal for: $signal"
        return
    }
    set ok [npi_fsdb_goto_time -vct $vct_hdl -time $begin_fsdb]
    if {$ok == 0} {
        set ok [npi_fsdb_goto_first -vct $vct_hdl]
    }
    set arr {}
    set truncated "__JSON_FALSE__"
    set count 0
    while {$ok != 0} {
        set t [npi_fsdb_vct_time -vct $vct_hdl]
        if {$t < $begin_fsdb} {
            set ok [npi_fsdb_goto_next -vct $vct_hdl]
            continue
        }
        if {$t > $end_fsdb} {break}
        set raw [npi_fsdb_vct_value -vct $vct_hdl -format $format]
        lappend arr [json_object_raw [list time $t raw [json_string $raw] radix [json_string $radix]]]
        incr count
        if {$count >= $max_rows} {
            set next_ok [npi_fsdb_goto_next -vct $vct_hdl]
            if {$next_ok != 0} {set truncated "__JSON_TRUE__"}
            break
        }
        set ok [npi_fsdb_goto_next -vct $vct_hdl]
    }
    catch {npi_fsdb_release_vct -vct $vct_hdl}
    catch {npi_fsdb_close -file $file_hdl}
    ok_data [list \
        signal [json_string $signal] \
        begin_time [json_string $begin_time] \
        end_time [json_string $end_time] \
        begin_fsdb $begin_fsdb \
        end_fsdb $end_fsdb \
        radix [json_string $radix] \
        changes [json_array_raw $arr] \
        truncated [json_value $truncated] \
        summary [json_object [list signal $signal change_count $count truncated $truncated]]]
}

proc scope_list_action {fsdb path max_depth max_rows} {
    if {$fsdb eq ""} {
        fail_data "RESOURCE_REQUIRED" "target.fsdb is required"
        return
    }
    set file_hdl [npi_fsdb_open -name $fsdb]
    if {$file_hdl eq ""} {
        fail_data "FSDB_OPEN_FAILED" "failed to open FSDB: $fsdb"
        return
    }
    set scopes {}
    set signals {}
    if {$path eq ""} {
        set scope_iter [npi_fsdb_iter_top_scope -file $file_hdl]
    } else {
        set root [npi_fsdb_scope_by_name -file $file_hdl -name $path -scope ""]
        if {$root eq ""} {
            catch {npi_fsdb_close -file $file_hdl}
            fail_data "SCOPE_NOT_FOUND" "scope not found: $path"
            return
        }
        set scope_iter [npi_fsdb_iter_child_scope -scope $root]
    }
    while {$scope_iter ne ""} {
        set s [npi_fsdb_iter_scope_next -iter $scope_iter]
        if {$s eq ""} {break}
        lappend scopes [npi_fsdb_scope_property_str -scope $s -type npiFsdbScopeFullName]
        if {[llength $scopes] >= $max_rows} {break}
    }
    if {$scope_iter ne ""} {catch {npi_fsdb_iter_scope_stop -iter $scope_iter}}
    set sig_scope ""
    if {$path ne ""} {set sig_scope [npi_fsdb_scope_by_name -file $file_hdl -name $path -scope ""]}
    if {$path eq ""} {
        set sig_iter [npi_fsdb_iter_top_sig -file $file_hdl]
    } elseif {$sig_scope ne ""} {
        set sig_iter [npi_fsdb_iter_sig -scope $sig_scope]
    } else {
        set sig_iter ""
    }
    while {$sig_iter ne ""} {
        set sig [npi_fsdb_iter_sig_next -iter $sig_iter]
        if {$sig eq ""} {break}
        lappend signals [npi_fsdb_sig_property_str -sig $sig -type npiFsdbSigFullName]
        if {[llength $signals] >= $max_rows} {break}
    }
    if {$sig_iter ne ""} {catch {npi_fsdb_iter_sig_stop -iter $sig_iter}}
    catch {npi_fsdb_close -file $file_hdl}
    ok_data [list \
        path [json_string $path] \
        scopes [json_array $scopes] \
        signals [json_array $signals] \
        signals_preview [json_array $signals] \
        summary [json_object [list path $path scope_count [llength $scopes] signal_count [llength $signals]]]]
}

proc active_trace_action {signal time} {
    if {$signal eq "" || $time eq ""} {
        fail_data "MISSING_FIELD" "args.signal and args.requested_time are required"
        return
    }
    set result {}
    set rc 0
    set call_error ""
    if {[catch {set rc [::npi_L1::npi_active_trace_driver $signal result $time]} call_error]} {
        set rc 0
        set result {}
    }
    set active_time ""
    if {[llength $result] >= 1} {
        set active_time [lindex $result 0]
    }
    set arr {}
    foreach item $result {
        lappend arr [json_string $item]
    }
    set dump_text ""
    set dump_rc 0
    set dump_error ""
    set dump_path [file join [pwd] "kdebug_active_trace_dump_[pid].txt"]
    if {[catch {
        set fp [open $dump_path w]
        set dump_rc [::npi_L1::npi_active_trace_driver_dump $signal $fp $time]
        close $fp
        set fp [open $dump_path r]
        set dump_text [read $fp]
        close $fp
        file delete -force $dump_path
    } dump_error]} {
        catch {close $fp}
        catch {file delete -force $dump_path}
        set dump_text ""
        set dump_rc 0
    }
    ok_data [list \
        signal [json_string $signal] \
        requested_time [json_string $time] \
        active_time [json_string $active_time] \
        status [json_string [expr {($rc > 0 || $dump_rc > 0 || $active_time ne "") ? "ok" : "not_found"}]] \
        active_call_rc $rc \
        active_call_error [json_string $call_error] \
        dump_rc $dump_rc \
        dump_error [json_string $dump_error] \
        active_dump [json_string $dump_text] \
        raw [json_array_raw $arr] \
        summary [json_object [list signal $signal requested_time $time active_time $active_time status [expr {($rc > 0 || $dump_rc > 0 || $active_time ne "") ? "ok" : "not_found"}]]]]
}

proc command_available {name} {
    expr {[llength [info commands $name]] > 0}
}

proc require_command {name} {
    if {[command_available $name]} {return 1}
    fail_data "NPI_COMMAND_UNAVAILABLE" "NPI command is unavailable in this Verdi runtime: $name"
    return 0
}

proc positive_limit {value fallback} {
    if {![string is integer -strict $value] || $value <= 0} {return $fallback}
    return $value
}

proc safe_nl_get_str {hdl prop} {
    if {$hdl eq ""} {return ""}
    if {[catch {npi_nl_get_str -property $prop -object $hdl} value]} {return ""}
    return $value
}

proc safe_nl_get {hdl prop} {
    if {$hdl eq ""} {return "__JSON_NULL__"}
    if {[catch {npi_nl_get -property $prop -object $hdl} value]} {return "__JSON_NULL__"}
    if {$value eq "" || $value eq "npiNlUndefined"} {return "__JSON_NULL__"}
    return $value
}

proc netlist_handle_json {hdl} {
    return [json_object [list \
        name [safe_nl_get_str $hdl npiNlName] \
        full_name [safe_nl_get_str $hdl npiNlFullName] \
        type [safe_nl_get_str $hdl npiNlType] \
        instance_type [safe_nl_get_str $hdl npiNlInstType] \
        cell_type [safe_nl_get_str $hdl npiNlCellType] \
        size [safe_nl_get $hdl npiNlSize]]]
}

proc valid_npi_enum {value prefix} {
    if {$value eq ""} {return 1}
    expr {[string first $prefix $value] == 0 && [regexp {^[A-Za-z0-9_]+$} $value]}
}

proc bool_value {value} {
    expr {[string tolower $value] in {1 true yes on}}
}

proc valid_hdl_identifier {value} {
    regexp {^[A-Za-z_][A-Za-z0-9_$]*$} $value
}

proc decode_hex_utf8 {value} {
    if {$value eq "-"} {return ""}
    if {![regexp {^([0-9A-Fa-f][0-9A-Fa-f])*$} $value]} {
        error "invalid hex-encoded plan field"
    }
    return [encoding convertfrom utf-8 [binary format H* $value]]
}

proc read_plan_rows {path expected_fields} {
    if {$path eq "" || ![file isfile $path]} {
        error "controlled action plan is missing: $path"
    }
    set fp [open $path r]
    fconfigure $fp -encoding utf-8 -translation lf
    set rows {}
    set line_number 0
    while {[gets $fp line] >= 0} {
        incr line_number
        if {$line eq ""} {continue}
        set fields [split $line "\t"]
        if {[llength $fields] != $expected_fields} {
            close $fp
            error "invalid controlled action plan row $line_number"
        }
        lappend rows $fields
    }
    close $fp
    return $rows
}

proc prepare_output_file {path overwrite} {
    if {$path eq ""} {
        fail_data "MISSING_FIELD" "args.output is required"
        return 0
    }
    if {[file exists $path]} {
        if {![bool_value $overwrite]} {
            fail_data "OUTPUT_EXISTS" "output already exists; set args.overwrite=true to replace it: $path"
            return 0
        }
        if {[file isdirectory $path]} {
            fail_data "OUTPUT_IS_DIRECTORY" "output file path is a directory: $path"
            return 0
        }
        file delete -force -- $path
    }
    file mkdir [file dirname $path]
    return 1
}

proc prepare_output_directory {path overwrite} {
    if {$path eq ""} {
        fail_data "MISSING_FIELD" "args.output_dir is required"
        return 0
    }
    if {[file exists $path] && ![file isdirectory $path]} {
        fail_data "OUTPUT_NOT_DIRECTORY" "output directory path is an existing file: $path"
        return 0
    }
    if {[file exists $path] && ![bool_value $overwrite]} {
        fail_data "OUTPUT_EXISTS" "output directory already exists; set args.overwrite=true to update it: $path"
        return 0
    }
    file mkdir $path
    return 1
}

proc netlist_resolve_action {name object_type} {
    if {$name eq ""} {
        fail_data "MISSING_FIELD" "args.name is required"
        return
    }
    if {![valid_npi_enum $object_type npiNl]} {
        fail_data "INVALID_ENUM" "args.object_type must be an npiNl* enum"
        return
    }
    if {![require_command npi_nl_handle_by_name]} {return}
    if {$object_type eq ""} {
        set hdl [npi_nl_handle_by_name -name $name]
    } else {
        set hdl [npi_nl_handle_by_name -name $name -type $object_type]
    }
    if {$hdl eq ""} {
        fail_data "NETLIST_OBJECT_NOT_FOUND" "netlist object not found: $name"
        return
    }
    set object_json [netlist_handle_json $hdl]
    catch {npi_nl_release_handle -object $hdl}
    ok_data [list \
        query [json_string $name] \
        requested_type [json_string $object_type] \
        object $object_json \
        summary [json_object [list name $name status resolved]]]
}

proc netlist_iterate_action {name object_type max_rows} {
    if {$object_type eq ""} {
        fail_data "MISSING_FIELD" "args.object_type is required"
        return
    }
    if {![valid_npi_enum $object_type npiNl]} {
        fail_data "INVALID_ENUM" "args.object_type must be an npiNl* enum"
        return
    }
    if {![require_command npi_nl_iterate]} {return}
    set ref ""
    if {$name ne ""} {
        set ref [npi_nl_handle_by_name -name $name]
        if {$ref eq ""} {
            fail_data "NETLIST_OBJECT_NOT_FOUND" "netlist reference object not found: $name"
            return
        }
    }
    set iter [npi_nl_iterate -type $object_type -refHandle $ref]
    set rows {}
    set limit [positive_limit $max_rows 200]
    set truncated 0
    if {$iter ne ""} {
        while {1} {
            set child [npi_nl_scan -iterator $iter]
            if {$child eq ""} {break}
            if {[llength $rows] >= $limit} {
                set truncated 1
                catch {npi_nl_release_handle -object $child}
                break
            }
            lappend rows [netlist_handle_json $child]
            catch {npi_nl_release_handle -object $child}
        }
    }
    if {$truncated && $iter ne ""} {catch {npi_nl_release_handle -object $iter}}
    if {$ref ne ""} {catch {npi_nl_release_handle -object $ref}}
    ok_data [list \
        reference [json_string $name] \
        object_type [json_string $object_type] \
        count [llength $rows] \
        truncated [json_value [expr {$truncated ? "__JSON_TRUE__" : "__JSON_FALSE__"}]] \
        items [json_array_raw $rows] \
        summary [json_object [list reference $name object_type $object_type count [llength $rows] truncated [expr {$truncated ? "__JSON_TRUE__" : "__JSON_FALSE__"}]]]]
}

proc safe_text_property {hdl prop} {
    if {$hdl eq ""} {return "__JSON_NULL__"}
    if {[catch {npi_text_property -type $prop -ref $hdl} value]} {return "__JSON_NULL__"}
    if {$value eq ""} {return "__JSON_NULL__"}
    return $value
}

proc safe_text_property_str {hdl prop} {
    if {$hdl eq ""} {return ""}
    if {[catch {npi_text_property_str -type $prop -ref $hdl} value]} {return ""}
    return $value
}

proc text_line_handles {file_name line_number file_var line_var} {
    upvar 1 $file_var file_hdl
    upvar 1 $line_var line_hdl
    set file_hdl ""
    set line_hdl ""
    if {$file_name eq "" || ![string is integer -strict $line_number] || $line_number <= 0} {
        fail_data "MISSING_FIELD" "args.file and a positive args.line are required"
        return 0
    }
    if {![require_command npi_text_file_by_name]} {return 0}
    set file_hdl [npi_text_file_by_name -name $file_name]
    if {$file_hdl eq ""} {
        fail_data "TEXT_FILE_NOT_FOUND" "NPI Text file not found: $file_name"
        return 0
    }
    set line_hdl [npi_text_line_by_number -ref $file_hdl -number $line_number]
    if {$line_hdl eq ""} {
        fail_data "TEXT_LINE_NOT_FOUND" "NPI Text line not found: $file_name:$line_number"
        return 0
    }
    return 1
}

proc text_line_action {file_name line_number} {
    if {![text_line_handles $file_name $line_number file_hdl line_hdl]} {return}
    set full_name [safe_text_property_str $file_hdl npiTextFileFullName]
    set content [safe_text_property_str $line_hdl npiTextLineContent]
    set word_count [safe_text_property $line_hdl npiTextWordCount]
    ok_data [list \
        file [json_string $file_name] \
        full_name [json_string $full_name] \
        line $line_number \
        content [json_string $content] \
        word_count [json_value $word_count] \
        summary [json_object [list file $file_name line $line_number word_count $word_count]]]
}

proc text_words_action {file_name line_number max_rows} {
    if {![text_line_handles $file_name $line_number file_hdl line_hdl]} {return}
    set iter [npi_text_iter_start -type npiTextWord -ref $line_hdl]
    set rows {}
    set limit [positive_limit $max_rows 200]
    set truncated 0
    if {$iter ne ""} {
        while {1} {
            set word [npi_text_iter_next -iter $iter]
            if {$word eq ""} {break}
            if {[llength $rows] >= $limit} {
                set truncated 1
                break
            }
            lappend rows [json_object [list \
                index [safe_text_property $word npiTextWordNumber] \
                text [safe_text_property_str $word npiTextWordName] \
                attribute [safe_text_property_str $word npiTextWordAttribute] \
                attribute_id [safe_text_property $word npiTextWordAttribute]]]
        }
        catch {npi_text_iter_stop -iter $iter}
    }
    ok_data [list \
        file [json_string $file_name] \
        line $line_number \
        count [llength $rows] \
        truncated [json_value [expr {$truncated ? "__JSON_TRUE__" : "__JSON_FALSE__"}]] \
        words [json_array_raw $rows] \
        summary [json_object [list file $file_name line $line_number count [llength $rows] truncated [expr {$truncated ? "__JSON_TRUE__" : "__JSON_FALSE__"}]]]]
}

proc text_replace_line_action {file_name line_number content output overwrite} {
    if {$output eq ""} {
        fail_data "MISSING_FIELD" "args.output is required"
        return
    }
    if {![text_line_handles $file_name $line_number file_hdl line_hdl]} {return}
    set source_full_name [safe_text_property_str $file_hdl npiTextFileFullName]
    if {$source_full_name ne "" && [file normalize $source_full_name] eq [file normalize $output]} {
        fail_data "IN_PLACE_EDIT_FORBIDDEN" "text.replace_line writes a copy; args.output must differ from the source file"
        return
    }
    if {![require_command npi_text_replace_line]} {return}
    if {![prepare_output_file $output $overwrite]} {return}
    set original [safe_text_property_str $line_hdl npiTextLineContent]
    set replaced [npi_text_replace_line -ref $line_hdl -content $content]
    if {$replaced eq ""} {
        catch {file delete -force -- $output}
        fail_data "TEXT_REPLACE_FAILED" "NPI Text Model failed to replace $file_name:$line_number"
        return
    }
    set rendered [safe_text_property_str $file_hdl npiTextFileContent]
    if {$rendered eq ""} {
        catch {file delete -force -- $output}
        fail_data "TEXT_RENDER_FAILED" "NPI Text Model returned empty file content after replacement"
        return
    }
    set fp [open $output w]
    fconfigure $fp -encoding utf-8 -translation lf
    puts -nonewline $fp $rendered
    close $fp
    ok_data [list \
        file [json_string $file_name] \
        full_name [json_string $source_full_name] \
        line $line_number \
        original [json_string $original] \
        replacement [json_string $content] \
        output [json_string $output] \
        summary [json_object [list file $file_name line $line_number output $output status written]]]
}

proc dm_writer_result {output_dir overwrite} {
    if {[bool_value $overwrite]} {
        return [npi_dm_write_text_mode -dir $output_dir -f]
    }
    return [npi_dm_write_text_mode -dir $output_dir]
}

proc dm_add_net_action {module_name net_name net_type packed_left packed_right output_dir overwrite} {
    if {$module_name eq "" || $net_name eq ""} {
        fail_data "MISSING_FIELD" "args.module and args.name are required"
        return
    }
    if {![valid_hdl_identifier $net_name]} {
        fail_data "INVALID_IDENTIFIER" "args.name must be a simple HDL identifier"
        return
    }
    if {$net_type eq ""} {set net_type npiDmNetWire}
    if {![valid_npi_enum $net_type npiDmNet]} {
        fail_data "INVALID_ENUM" "args.net_type must be an npiDmNet* enum"
        return
    }
    foreach command {npi_dm_module_by_name npi_dm_add_net npi_dm_write_text_mode} {
        if {![require_command $command]} {return}
    }
    set module_hdl [npi_dm_module_by_name -name $module_name]
    if {$module_hdl eq ""} {
        fail_data "DM_MODULE_NOT_FOUND" "DM module not found: $module_name"
        return
    }
    set data_type ""
    if {$packed_left ne "" || $packed_right ne ""} {
        if {![string is integer -strict $packed_left] || ![string is integer -strict $packed_right]} {
            fail_data "INVALID_RANGE" "args.packed_left and args.packed_right must both be integers"
            return
        }
        foreach command {npi_dm_create_range npi_dm_create_npiDmHandleArray npi_dm_create_npiDmBasicDataType} {
            if {![require_command $command]} {return}
        }
        set range [npi_dm_create_range -left $packed_left -right $packed_right]
        set packed_dim [npi_dm_create_npiDmHandleArray -array_list $range]
        set data_type [npi_dm_create_npiDmBasicDataType -type npiDmDtDefault -sign npiDmSignNone -packed_dim $packed_dim]
    }
    if {![prepare_output_directory $output_dir $overwrite]} {return}
    set added [npi_dm_add_net -scope $module_hdl -name $net_name -data_type $data_type -unpacked_dim "" -net_type $net_type]
    if {$added eq ""} {
        fail_data "DM_ADD_NET_FAILED" "failed to add net $net_name to module $module_name"
        return
    }
    if {![dm_writer_result $output_dir $overwrite]} {
        fail_data "DM_WRITE_FAILED" "failed to write modified design to $output_dir"
        return
    }
    ok_data [list \
        module [json_string $module_name] \
        name [json_string $net_name] \
        net_type [json_string $net_type] \
        packed_left [expr {$packed_left eq "" ? "null" : $packed_left}] \
        packed_right [expr {$packed_right eq "" ? "null" : $packed_right}] \
        output_dir [json_string $output_dir] \
        summary [json_object [list module $module_name name $net_name output_dir $output_dir status written]]]
}

proc dm_clone_module_action {module_name new_name output_dir overwrite} {
    if {$module_name eq "" || $new_name eq ""} {
        fail_data "MISSING_FIELD" "args.module and args.new_name are required"
        return
    }
    if {![valid_hdl_identifier $new_name]} {
        fail_data "INVALID_IDENTIFIER" "args.new_name must be a simple HDL identifier"
        return
    }
    foreach command {npi_dm_module_by_name npi_dm_clone_module npi_dm_write_text_mode} {
        if {![require_command $command]} {return}
    }
    set module_hdl [npi_dm_module_by_name -name $module_name]
    if {$module_hdl eq ""} {
        fail_data "DM_MODULE_NOT_FOUND" "DM module not found: $module_name"
        return
    }
    if {![prepare_output_directory $output_dir $overwrite]} {return}
    set clone [npi_dm_clone_module -module $module_hdl -name $new_name]
    if {$clone eq ""} {
        fail_data "DM_CLONE_FAILED" "failed to clone module $module_name as $new_name"
        return
    }
    if {![dm_writer_result $output_dir $overwrite]} {
        fail_data "DM_WRITE_FAILED" "failed to write cloned module to $output_dir"
        return
    }
    ok_data [list \
        module [json_string $module_name] \
        new_name [json_string $new_name] \
        output_dir [json_string $output_dir] \
        summary [json_object [list module $module_name new_name $new_name output_dir $output_dir status written]]]
}

proc safe_vcs_get {hdl prop} {
    if {$hdl eq ""} {return "__JSON_NULL__"}
    if {[catch {npi_vcs_get -property $prop -object $hdl} value]} {return "__JSON_NULL__"}
    if {$value eq "" || $value eq "-1"} {return "__JSON_NULL__"}
    return $value
}

proc safe_vcs_get_str {hdl prop} {
    if {$hdl eq ""} {return ""}
    if {[catch {npi_vcs_get_str -property $prop -object $hdl} value]} {return ""}
    return $value
}

proc vcs_summary_action {database} {
    if {$database eq ""} {
        fail_data "MISSING_FIELD" "target.daidir or args.database is required"
        return
    }
    if {![require_command npi_vcs_open]} {return}
    set db [npi_vcs_open -dir $database]
    if {$db eq ""} {
        fail_data "VCS_DB_OPEN_FAILED" "failed to open VCS database; compile with -Xdump_vcsdb: $database"
        return
    }
    set comp [npi_vcs_handle -type npiVcsCompilation -refHandle $db]
    set stats [npi_vcs_handle -type npiVcsDesignStats -refHandle $db]
    set sim [npi_vcs_handle -type npiVcsSimulation -refHandle $db]
    set compilation [json_object [list \
        path [safe_vcs_get_str $comp npiVcsPath] \
        options [safe_vcs_get_str $comp npiVcsOptions] \
        warnings [safe_vcs_get $comp npiVcsWarningNo] \
        errors [safe_vcs_get $comp npiVcsErrorNo] \
        result [safe_vcs_get $comp npiVcsResult]]]
    set design [json_object [list \
        modules [safe_vcs_get $stats npiVcsModuleNo] \
        verilog_files [safe_vcs_get $stats npiVcsVlogNo] \
        systemverilog_files [safe_vcs_get $stats npiVcsSvNo]]]
    set simulation [json_object [list \
        path [safe_vcs_get_str $sim npiVcsPath] \
        options [safe_vcs_get_str $sim npiVcsOptions] \
        test_count [safe_vcs_get $sim npiVcsTestNo] \
        waveform_count [safe_vcs_get $sim npiVcsWaveformNo]]]
    set db_name [safe_vcs_get_str $db npiVcsName]
    set tool_name [safe_vcs_get_str $db npiVcsToolName]
    set tool_version [safe_vcs_get_str $db npiVcsToolVersion]
    set warning_count [safe_vcs_get $comp npiVcsWarningNo]
    set error_count [safe_vcs_get $comp npiVcsErrorNo]
    set module_count [safe_vcs_get $stats npiVcsModuleNo]
    catch {npi_vcs_close -db $db}
    ok_data [list \
        database [json_string $database] \
        name [json_string $db_name] \
        tool [json_object [list name $tool_name version $tool_version]] \
        compilation $compilation \
        design $design \
        simulation $simulation \
        summary [json_object [list database $database warnings $warning_count errors $error_count modules $module_count]]]
}

proc safe_pw_property {hdl prop} {
    if {$hdl eq ""} {return "__JSON_NULL__"}
    if {[catch {npi_pw_property -type $prop -ref $hdl} value]} {return "__JSON_NULL__"}
    if {$value eq ""} {return "__JSON_NULL__"}
    return $value
}

proc safe_pw_property_str {hdl prop} {
    if {$hdl eq ""} {return ""}
    if {[catch {npi_pw_property_str -type $prop -ref $hdl} value]} {return ""}
    return $value
}

proc power_handle_json {hdl} {
    return [json_object [list \
        name [safe_pw_property_str $hdl npiPwName] \
        full_name [safe_pw_property_str $hdl npiPwFullName] \
        type [safe_pw_property_str $hdl npiPwType] \
        file [safe_pw_property_str $hdl npiPwDefFile] \
        line [safe_pw_property $hdl npiPwLineNo]]]
}

proc power_resolve_action {name object_type} {
    if {$name eq ""} {
        fail_data "MISSING_FIELD" "args.name is required"
        return
    }
    if {![valid_npi_enum $object_type npiPw]} {
        fail_data "INVALID_ENUM" "args.object_type must be an npiPw* enum"
        return
    }
    if {![require_command npi_pw_handle_by_name]} {return}
    if {$object_type eq ""} {
        set hdl [npi_pw_handle_by_name -name $name]
    } else {
        set hdl [npi_pw_handle_by_name -name $name -type $object_type]
    }
    if {$hdl eq ""} {
        fail_data "POWER_OBJECT_NOT_FOUND" "power object not found: $name"
        return
    }
    ok_data [list \
        query [json_string $name] \
        requested_type [json_string $object_type] \
        object [power_handle_json $hdl] \
        summary [json_object [list name $name status resolved]]]
}

proc power_list_action {name object_type max_rows} {
    if {$name eq "" || $object_type eq ""} {
        fail_data "MISSING_FIELD" "args.name and args.object_type are required"
        return
    }
    if {![valid_npi_enum $object_type npiPw]} {
        fail_data "INVALID_ENUM" "args.object_type must be an npiPw* enum"
        return
    }
    foreach command {npi_pw_handle_by_name npi_pw_iter_start npi_pw_iter_next npi_pw_iter_stop} {
        if {![require_command $command]} {return}
    }
    set ref [npi_pw_handle_by_name -name $name]
    if {$ref eq ""} {
        fail_data "POWER_OBJECT_NOT_FOUND" "power reference object not found: $name"
        return
    }
    set iter [npi_pw_iter_start -type $object_type -ref $ref]
    set rows {}
    set limit [positive_limit $max_rows 200]
    set truncated 0
    if {$iter ne ""} {
        while {1} {
            set child [npi_pw_iter_next -iter $iter]
            if {$child eq ""} {break}
            if {[llength $rows] >= $limit} {set truncated 1; break}
            lappend rows [power_handle_json $child]
        }
        catch {npi_pw_iter_stop -iter $iter}
    }
    ok_data [list \
        reference [json_string $name] \
        object_type [json_string $object_type] \
        count [llength $rows] \
        truncated [json_value [expr {$truncated ? "__JSON_TRUE__" : "__JSON_FALSE__"}]] \
        items [json_array_raw $rows] \
        summary [json_object [list reference $name object_type $object_type count [llength $rows] truncated [expr {$truncated ? "__JSON_TRUE__" : "__JSON_FALSE__"}]]]]
}

proc safe_crdb_get {hdl prop} {
    if {$hdl eq "" || $hdl eq "0"} {return "__JSON_NULL__"}
    if {[catch {npi_crdb_get -type $prop -ref $hdl} value]} {return "__JSON_NULL__"}
    if {$value eq ""} {return "__JSON_NULL__"}
    return $value
}

proc safe_crdb_get_str {hdl prop} {
    if {$hdl eq "" || $hdl eq "0"} {return ""}
    if {[catch {npi_crdb_get_str -type $prop -ref $hdl} value]} {return ""}
    return $value
}

proc crdb_handle_json {hdl} {
    return [json_object [list \
        name [safe_crdb_get_str $hdl npiCrdbName] \
        full_name [safe_crdb_get_str $hdl npiCrdbFullName] \
        type [safe_crdb_get_str $hdl npiCrdbType] \
        definition [safe_crdb_get_str $hdl npiCrdbDefName] \
        level [safe_crdb_get $hdl npiCrdbGRType] \
        language [safe_crdb_get $hdl npiCrdbLangType] \
        size [safe_crdb_get $hdl npiCrdbSize] \
        signal_type [safe_crdb_get $hdl npiCrdbSigType] \
        port_direction [safe_crdb_get $hdl npiCrdbPortDir]]]
}

proc crdb_open_and_resolve {database name level db_var hdl_var} {
    upvar 1 $db_var db
    upvar 1 $hdl_var hdl
    set db ""
    set hdl ""
    if {$database eq "" || $name eq ""} {
        fail_data "MISSING_FIELD" "args.crdb and args.name are required"
        return 0
    }
    set level [string toupper $level]
    if {$level ne "RTL" && $level ne "GATE"} {
        fail_data "INVALID_ENUM" "args.level must be RTL or GATE"
        return 0
    }
    if {![require_command npi_crdb_open]} {return 0}
    set db [npi_crdb_open -name $database]
    if {$db eq "" || $db eq "0"} {
        fail_data "CRDB_OPEN_FAILED" "failed to open CRDB: $database"
        return 0
    }
    set native_level [expr {$level eq "RTL" ? "npiCrdbLevelRTL" : "npiCrdbLevelGate"}]
    set hdl [npi_crdb_handle_by_name -db $db -name $name -level $native_level]
    if {$hdl eq "" || $hdl eq "0"} {
        set hdl [npi_crdb_handle_by_name -db $db -name $name -level $level]
    }
    if {$hdl eq "" || $hdl eq "0"} {
        catch {npi_crdb_close -crdb $db}
        fail_data "CRDB_OBJECT_NOT_FOUND" "CRDB object not found at $level level: $name"
        return 0
    }
    return 1
}

proc crdb_resolve_action {database name level} {
    if {![crdb_open_and_resolve $database $name $level db hdl]} {return}
    set object_json [crdb_handle_json $hdl]
    catch {npi_crdb_release_handle -handle $hdl}
    catch {npi_crdb_close -crdb $db}
    ok_data [list \
        database [json_string $database] \
        query [json_string $name] \
        level [json_string [string toupper $level]] \
        object $object_json \
        summary [json_object [list name $name level [string toupper $level] status resolved]]]
}

proc crdb_correlates_action {database name level max_rows} {
    if {![crdb_open_and_resolve $database $name $level db hdl]} {return}
    set iter [npi_crdb_iter_start -type npiCrdbCorrelate -ref $hdl]
    set rows {}
    set limit [positive_limit $max_rows 200]
    set truncated 0
    if {$iter ne "" && $iter ne "0"} {
        while {1} {
            set mapped [npi_crdb_iter_next -iter $iter]
            if {$mapped eq "" || $mapped eq "0"} {break}
            if {[llength $rows] >= $limit} {set truncated 1; break}
            lappend rows [crdb_handle_json $mapped]
            catch {npi_crdb_release_handle -handle $mapped}
        }
        catch {npi_crdb_iter_stop -iter $iter}
    }
    if {[llength $rows] == 0 && [llength [info commands ::npi_L1::npi_crdb_corr_sig]] != 0} {
        set correlated_handles {}
        if {[::npi_L1::npi_crdb_corr_sig $hdl correlated_handles] > 0} {
            foreach mapped $correlated_handles {
                if {[llength $rows] >= $limit} {
                    set truncated 1
                    catch {npi_crdb_release_handle -handle $mapped}
                    continue
                }
                lappend rows [crdb_handle_json $mapped]
                catch {npi_crdb_release_handle -handle $mapped}
            }
        }
    }
    catch {npi_crdb_release_handle -handle $hdl}
    catch {npi_crdb_close -crdb $db}
    ok_data [list \
        database [json_string $database] \
        query [json_string $name] \
        level [json_string [string toupper $level]] \
        count [llength $rows] \
        truncated [json_value [expr {$truncated ? "__JSON_TRUE__" : "__JSON_FALSE__"}]] \
        correlated [json_array_raw $rows] \
        summary [json_object [list name $name level [string toupper $level] count [llength $rows] truncated [expr {$truncated ? "__JSON_TRUE__" : "__JSON_FALSE__"}]]]]
}

proc transaction_writer_action {output overwrite unit begin_time stream transaction_plan tag_plan relation_plan} {
    if {$stream eq ""} {
        fail_data "MISSING_FIELD" "args.stream is required"
        return
    }
    if {![regexp {^(1|10|100)(s|ms|us|ns|ps|fs)$} $unit]} {
        fail_data "INVALID_TIME_UNIT" "args.unit must match (1|10|100)(s|ms|us|ns|ps|fs)"
        return
    }
    if {![string is integer -strict $begin_time] || $begin_time < 0} {
        fail_data "INVALID_TIME" "args.begin_time must be a non-negative integer"
        return
    }
    foreach command {npi_fsdbw_open npi_fsdbw_stream_begin npi_fsdbw_stream_end npi_fsdbw_incr_time npi_fsdbw_trans_begin npi_fsdbw_set_label npi_fsdbw_add_tag npi_fsdbw_trans_end npi_fsdbw_add_relation npi_fsdbw_close} {
        if {![require_command $command]} {return}
    }
    if {[catch {set transaction_rows [read_plan_rows $transaction_plan 4]} plan_error]} {
        fail_data "INVALID_PLAN" $plan_error
        return
    }
    if {[llength $transaction_rows] == 0} {
        fail_data "MISSING_FIELD" "args.transactions must contain at least one transaction"
        return
    }
    set tag_rows {}
    if {$tag_plan ne ""} {
        if {[catch {set tag_rows [read_plan_rows $tag_plan 2]} plan_error]} {
            fail_data "INVALID_PLAN" $plan_error
            return
        }
    }
    set relation_rows {}
    if {$relation_plan ne ""} {
        if {[catch {set relation_rows [read_plan_rows $relation_plan 3]} plan_error]} {
            fail_data "INVALID_PLAN" $plan_error
            return
        }
    }
    if {![prepare_output_file $output $overwrite]} {return}
    set file_hdl ""
    set stream_hdl ""
    set transaction_handles {}
    set current_time $begin_time
    set rc [catch {
        set file_hdl [npi_fsdbw_open -name $output -unit $unit -time $begin_time]
        if {$file_hdl eq ""} {error "npi_fsdbw_open failed for $output"}
        set stream_hdl [npi_fsdbw_stream_begin -file $file_hdl -name $stream]
        if {$stream_hdl eq ""} {error "npi_fsdbw_stream_begin failed for $stream"}
        if {![npi_fsdbw_stream_end -stream $stream_hdl]} {error "npi_fsdbw_stream_end failed for $stream"}
        set transaction_index 0
        foreach row $transaction_rows {
            lassign $row start_delta duration transaction_type label_hex
            if {![string is integer -strict $start_delta] || $start_delta < 0} {error "invalid start_delta at transaction $transaction_index"}
            if {![string is integer -strict $duration] || $duration <= 0} {error "invalid duration at transaction $transaction_index"}
            if {![valid_npi_enum $transaction_type npiFsdbwTrans]} {error "invalid transaction type at transaction $transaction_index"}
            if {$start_delta > 0 && ![npi_fsdbw_incr_time -file $file_hdl -time $start_delta]} {error "failed to advance start_delta at transaction $transaction_index"}
            incr current_time $start_delta
            set transaction_hdl [npi_fsdbw_trans_begin -stream $stream_hdl -type $transaction_type]
            if {$transaction_hdl eq ""} {error "failed to begin transaction $transaction_index"}
            set label [decode_hex_utf8 $label_hex]
            if {$label ne "" && ![npi_fsdbw_set_label -trans $transaction_hdl -label $label]} {error "failed to set label at transaction $transaction_index"}
            foreach tag_row $tag_rows {
                lassign $tag_row tag_index tag_hex
                if {$tag_index == $transaction_index} {
                    set tag [decode_hex_utf8 $tag_hex]
                    if {$tag eq "" || ![npi_fsdbw_add_tag -trans $transaction_hdl -tag $tag]} {error "failed to add tag at transaction $transaction_index"}
                }
            }
            if {![npi_fsdbw_incr_time -file $file_hdl -time $duration]} {error "failed to advance duration at transaction $transaction_index"}
            incr current_time $duration
            if {![npi_fsdbw_trans_end -trans $transaction_hdl]} {error "failed to end transaction $transaction_index"}
            lappend transaction_handles $transaction_hdl
            incr transaction_index
        }
        foreach row $relation_rows {
            lassign $row relation_hex master_index slave_index
            if {![string is integer -strict $master_index] || ![string is integer -strict $slave_index]} {error "relation indexes must be integers"}
            if {$master_index < 0 || $slave_index < 0 || $master_index >= [llength $transaction_handles] || $slave_index >= [llength $transaction_handles]} {error "relation index is outside args.transactions"}
            set relation [decode_hex_utf8 $relation_hex]
            if {$relation eq "" || ![npi_fsdbw_add_relation -relation $relation -master [lindex $transaction_handles $master_index] -slave [lindex $transaction_handles $slave_index]]} {error "failed to add relation between $master_index and $slave_index"}
        }
    } writer_error writer_options]
    if {$file_hdl ne ""} {
        set close_rc [catch {npi_fsdbw_close -file $file_hdl} close_error]
        if {$close_rc && !$rc} {
            set rc 1
            set writer_error "failed to close transaction FSDB: $close_error"
        }
    }
    if {$rc} {
        catch {file delete -force -- $output}
        fail_data "TRANSACTION_WRITER_FAILED" $writer_error
        return
    }
    ok_data [list \
        output [json_string $output] \
        unit [json_string $unit] \
        begin_time $begin_time \
        end_time $current_time \
        stream [json_string $stream] \
        transaction_count [llength $transaction_rows] \
        relation_count [llength $relation_rows] \
        summary [json_object [list output $output stream $stream transaction_count [llength $transaction_rows] relation_count [llength $relation_rows] status written]]]
}

proc fsdb_writer_create_scope_action {output overwrite unit begin_time end_time_delta operation_plan} {
    if {![regexp {^(1|10|100)(s|ms|us|ns|ps|fs)$} $unit]} {
        fail_data "INVALID_TIME_UNIT" "args.unit must match (1|10|100)(s|ms|us|ns|ps|fs)"
        return
    }
    if {![string is integer -strict $begin_time] || $begin_time < 0 || ![string is integer -strict $end_time_delta] || $end_time_delta < 0} {
        fail_data "INVALID_TIME" "args.begin_time and args.end_time_delta must be non-negative integers"
        return
    }
    foreach command {npi_fsdbw_create npi_fsdbw_begin_hierarchy_creation npi_fsdbw_create_scope npi_fsdbw_up_scope npi_fsdbw_end_hierarchy_creation npi_fsdbw_incr_time npi_fsdbw_close} {
        if {![require_command $command]} {return}
    }
    if {[catch {set operation_rows [read_plan_rows $operation_plan 4]} plan_error]} {
        fail_data "INVALID_PLAN" $plan_error
        return
    }
    if {[llength $operation_rows] == 0} {
        fail_data "MISSING_FIELD" "args.operations or args.scopes must contain at least one scope"
        return
    }
    if {![prepare_output_file $output $overwrite]} {return}
    set file_hdl ""
    set scope_count 0
    set up_count 0
    set depth 0
    set rc [catch {
        set file_hdl [npi_fsdbw_create -name $output -unit $unit -time $begin_time]
        if {$file_hdl eq ""} {error "npi_fsdbw_create failed for $output"}
        npi_fsdbw_begin_hierarchy_creation -file $file_hdl
        foreach row $operation_rows {
            lassign $row operation object_type name_hex definition_hex
            if {$operation eq "up"} {
                if {$depth <= 0 || ![npi_fsdbw_up_scope -file $file_hdl]} {error "cannot move above the FSDB hierarchy root"}
                incr depth -1
                incr up_count
                continue
            }
            if {$operation ne "scope"} {error "unsupported FSDB hierarchy operation: $operation"}
            if {![valid_npi_enum $object_type npiFsdbScope]} {error "invalid FSDB scope type: $object_type"}
            set name [decode_hex_utf8 $name_hex]
            set definition [decode_hex_utf8 $definition_hex]
            if {$name eq ""} {error "FSDB scope name cannot be empty"}
            if {$definition eq ""} {
                set created [npi_fsdbw_create_scope -file $file_hdl -type $object_type -name $name]
            } else {
                set created [npi_fsdbw_create_scope -file $file_hdl -type $object_type -name $name -def_name $definition]
            }
            if {!$created} {error "failed to create FSDB scope: $name"}
            incr depth
            incr scope_count
        }
        npi_fsdbw_end_hierarchy_creation -file $file_hdl
        if {$end_time_delta > 0 && ![npi_fsdbw_incr_time -file $file_hdl -time $end_time_delta]} {error "failed to advance FSDB end time"}
    } writer_error writer_options]
    if {$file_hdl ne ""} {
        set close_rc [catch {npi_fsdbw_close -file $file_hdl} close_error]
        if {$close_rc && !$rc} {
            set rc 1
            set writer_error "failed to close signal FSDB: $close_error"
        }
    }
    if {$rc} {
        catch {file delete -force -- $output}
        fail_data "FSDB_WRITER_FAILED" $writer_error
        return
    }
    ok_data [list \
        output [json_string $output] \
        unit [json_string $unit] \
        begin_time $begin_time \
        end_time [expr {$begin_time + $end_time_delta}] \
        scope_count $scope_count \
        up_count $up_count \
        summary [json_object [list output $output scope_count $scope_count up_count $up_count status written]]]
}

proc npi_capabilities_action {} {
    set domains {
        language {npi_handle_by_name npi_handle npi_get npi_get_str npi_get_value npi_iterate npi_scan}
        module_library {::npi_L1::npi_mod_define_get_inst ::npi_L1::npi_mod_inst_get_cont_assign ::npi_L1::npi_mod_inst_get_func ::npi_L1::npi_mod_inst_get_gen_scope ::npi_L1::npi_mod_inst_get_instance ::npi_L1::npi_mod_inst_get_instance_in_gen_scope ::npi_L1::npi_mod_inst_get_io ::npi_L1::npi_mod_inst_get_lang_interface ::npi_L1::npi_mod_inst_get_net ::npi_L1::npi_mod_inst_get_parameter ::npi_L1::npi_mod_inst_get_port ::npi_L1::npi_mod_inst_get_primitive ::npi_L1::npi_mod_inst_get_process_always ::npi_L1::npi_mod_inst_get_process_init ::npi_L1::npi_mod_inst_get_task ::npi_L1::npi_mod_inst_get_var}
        netlist {npi_nl_handle_by_name npi_nl_get npi_nl_get_str npi_nl_iterate npi_nl_scan}
        text {npi_text_file_by_name npi_text_line_by_number npi_text_iter_start npi_text_replace_line}
        design_manipulation {npi_dm_module_by_name npi_dm_add_net npi_dm_clone_module npi_dm_write_text_mode}
        fsdb_reader {npi_fsdb_open npi_fsdb_sig_by_name npi_fsdb_create_vct npi_fsdb_vct_value}
        transaction_writer {npi_fsdbw_open npi_fsdbw_stream_begin npi_fsdbw_trans_begin npi_fsdbw_trans_end}
        fsdb_writer {npi_fsdbw_create npi_fsdbw_begin_hierarchy_creation npi_fsdbw_create_scope}
        coverage {npi_cov_open npi_cov_get npi_cov_iter_start npi_cov_merge_test}
        vcs {npi_vcs_open npi_vcs_handle npi_vcs_get npi_vcs_get_str}
        power {npi_pw_handle_by_name npi_pw_iter_start npi_pw_property npi_pw_property_str}
        crdb {npi_crdb_open npi_crdb_handle_by_name npi_crdb_iter_start npi_crdb_get_str}
    }
    set rows {}
    set available_domains 0
    foreach {domain commands} $domains {
        set command_rows {}
        set available 1
        foreach command $commands {
            set present [command_available $command]
            if {!$present} {set available 0}
            lappend command_rows [json_object [list command $command available [expr {$present ? "__JSON_TRUE__" : "__JSON_FALSE__"}]]]
        }
        if {$available} {incr available_domains}
        lappend rows [json_object_raw [list \
            domain [json_string $domain] \
            available [expr {$available ? "true" : "false"}] \
            commands [json_array_raw $command_rows]]]
    }
    ok_data [list \
        domains [json_array_raw $rows] \
        summary [json_object [list domain_count [expr {[llength $domains] / 2}] available_domain_count $available_domains]]]
}

proc main {} {
    source_l1
    if {![import_elab_if_requested]} {return}
    set action [env_or_empty KDEBUG_TCL_ACTION]
    if {$action eq "port.trace_batch"} {
        uplevel #0 [list source [file join $::kdebug_npi_script_dir kdebug_port_trace.tcl]]
    }
    if {$action eq "trace.driver"} {
        trace_action driver [env_or_empty KDEBUG_TCL_SIGNAL] [env_or_empty KDEBUG_TCL_MAX_ROWS]
    } elseif {$action eq "trace.load" || $action eq "trace.query"} {
        set mode [env_or_empty KDEBUG_TCL_TRACE_MODE]
        if {$mode eq ""} {set mode load}
        trace_action $mode [env_or_empty KDEBUG_TCL_SIGNAL] [env_or_empty KDEBUG_TCL_MAX_ROWS]
    } elseif {$action eq "port.trace_batch"} {
        port_trace_batch_action \
            [env_or_empty KDEBUG_TCL_MODULE] \
            [env_or_empty KDEBUG_TCL_PORT_PLAN] \
            [env_or_empty KDEBUG_TCL_STOP_INSTANCE_PLAN] \
            [env_or_empty KDEBUG_TCL_SOURCE] \
            [env_or_empty KDEBUG_TCL_SOURCE_FALLBACK] \
            [env_or_empty KDEBUG_TCL_INCLUDE_FULL] \
            [env_or_empty KDEBUG_TCL_INCLUDE_BOUNDARY] \
            [env_or_empty KDEBUG_TCL_MAX_PARENT_DEPTH] \
            [env_or_empty KDEBUG_TCL_MAX_ASSIGN_DEPTH] \
            [env_or_empty KDEBUG_TCL_MAX_EXPR_DEPTH] \
            [env_or_empty KDEBUG_TCL_MAX_NODES] \
            [env_or_empty KDEBUG_TCL_MAX_EDGES] \
            [env_or_empty KDEBUG_TCL_MAX_API_RESULTS] \
            [env_or_empty KDEBUG_TCL_MAX_ROWS] \
            [env_or_empty KDEBUG_TCL_TRACE_DEBUG]
    } elseif {$action eq "signal.resolve"} {
        resolve_action [env_or_empty KDEBUG_TCL_SIGNAL]
    } elseif {$action eq "signal.canonicalize"} {
        canonicalize_action [env_or_empty KDEBUG_TCL_SIGNAL]
    } elseif {$action eq "signal.info"} {
        signal_info_action [env_or_empty KDEBUG_TCL_FSDB] [env_or_empty KDEBUG_TCL_SIGNAL]
    } elseif {$action eq "signal.scan"} {
        signal_scan_action [env_or_empty KDEBUG_TCL_FSDB] [env_or_empty KDEBUG_TCL_SIGNAL] [env_or_empty KDEBUG_TCL_BEGIN] [env_or_empty KDEBUG_TCL_END] [env_or_empty KDEBUG_TCL_FORMAT] [env_or_empty KDEBUG_TCL_MAX_ROWS]
    } elseif {$action eq "value.at"} {
        value_at_action [env_or_empty KDEBUG_TCL_FSDB] [env_or_empty KDEBUG_TCL_SIGNAL] [env_or_empty KDEBUG_TCL_TIME] [env_or_empty KDEBUG_TCL_FORMAT]
    } elseif {$action eq "value.batch_at"} {
        value_batch_at_action [env_or_empty KDEBUG_TCL_FSDB] [split [env_or_empty KDEBUG_TCL_SIGNALS] "\n"] [env_or_empty KDEBUG_TCL_TIME] [env_or_empty KDEBUG_TCL_FORMAT]
    } elseif {$action eq "scope.list"} {
        scope_list_action [env_or_empty KDEBUG_TCL_FSDB] [env_or_empty KDEBUG_TCL_SCOPE] [env_or_empty KDEBUG_TCL_MAX_DEPTH] [env_or_empty KDEBUG_TCL_MAX_ROWS]
    } elseif {$action eq "trace.active_driver" || $action eq "trace.active_driver_chain"} {
        active_trace_action [env_or_empty KDEBUG_TCL_SIGNAL] [env_or_empty KDEBUG_TCL_TIME]
    } elseif {$action eq "npi.capabilities"} {
        npi_capabilities_action
    } elseif {$action eq "language.resolve"} {
        language_resolve_action [env_or_empty KDEBUG_TCL_NAME] [env_or_empty KDEBUG_TCL_SCOPE]
    } elseif {$action eq "language.iterate"} {
        language_iterate_action [env_or_empty KDEBUG_TCL_NAME] [env_or_empty KDEBUG_TCL_SCOPE] [env_or_empty KDEBUG_TCL_OBJECT_TYPE] [env_or_empty KDEBUG_TCL_MAX_ROWS]
    } elseif {$action eq "language.relate"} {
        language_relate_action [env_or_empty KDEBUG_TCL_NAME] [env_or_empty KDEBUG_TCL_SCOPE] [env_or_empty KDEBUG_TCL_RELATION_TYPE]
    } elseif {$action eq "language.value"} {
        language_value_action [env_or_empty KDEBUG_TCL_NAME] [env_or_empty KDEBUG_TCL_SCOPE] [env_or_empty KDEBUG_TCL_VALUE_FORMAT]
    } elseif {$action eq "module.objects"} {
        module_objects_action [env_or_empty KDEBUG_TCL_MODULE] [env_or_empty KDEBUG_TCL_KIND] [env_or_empty KDEBUG_TCL_MAX_ROWS]
    } elseif {$action eq "module.find_instances"} {
        module_find_instances_action [env_or_empty KDEBUG_TCL_DEFINITION] [env_or_empty KDEBUG_TCL_MAX_ROWS]
    } elseif {$action eq "module.inspect"} {
        module_inspect_action [env_or_empty KDEBUG_TCL_MODULE] [env_or_empty KDEBUG_TCL_SECTIONS] [env_or_empty KDEBUG_TCL_MAX_ROWS]
    } elseif {$action eq "module.inspect_batch"} {
        module_inspect_batch_action [env_or_empty KDEBUG_TCL_BATCH_PLAN] [env_or_empty KDEBUG_TCL_SECTIONS] [env_or_empty KDEBUG_TCL_MAX_ROWS]
    } elseif {$action eq "netlist.resolve"} {
        netlist_resolve_action [env_or_empty KDEBUG_TCL_NAME] [env_or_empty KDEBUG_TCL_OBJECT_TYPE]
    } elseif {$action eq "netlist.iterate"} {
        netlist_iterate_action [env_or_empty KDEBUG_TCL_NAME] [env_or_empty KDEBUG_TCL_OBJECT_TYPE] [env_or_empty KDEBUG_TCL_MAX_ROWS]
    } elseif {$action eq "text.line"} {
        text_line_action [env_or_empty KDEBUG_TCL_FILE] [env_or_empty KDEBUG_TCL_LINE]
    } elseif {$action eq "text.words"} {
        text_words_action [env_or_empty KDEBUG_TCL_FILE] [env_or_empty KDEBUG_TCL_LINE] [env_or_empty KDEBUG_TCL_MAX_ROWS]
    } elseif {$action eq "text.replace_line"} {
        text_replace_line_action [env_or_empty KDEBUG_TCL_FILE] [env_or_empty KDEBUG_TCL_LINE] [env_or_empty KDEBUG_TCL_CONTENT] [env_or_empty KDEBUG_TCL_OUTPUT] [env_or_empty KDEBUG_TCL_OVERWRITE]
    } elseif {$action eq "dm.add_net"} {
        dm_add_net_action [env_or_empty KDEBUG_TCL_MODULE] [env_or_empty KDEBUG_TCL_NAME] [env_or_empty KDEBUG_TCL_NET_TYPE] [env_or_empty KDEBUG_TCL_PACKED_LEFT] [env_or_empty KDEBUG_TCL_PACKED_RIGHT] [env_or_empty KDEBUG_TCL_OUTPUT_DIR] [env_or_empty KDEBUG_TCL_OVERWRITE]
    } elseif {$action eq "dm.clone_module"} {
        dm_clone_module_action [env_or_empty KDEBUG_TCL_MODULE] [env_or_empty KDEBUG_TCL_NEW_NAME] [env_or_empty KDEBUG_TCL_OUTPUT_DIR] [env_or_empty KDEBUG_TCL_OVERWRITE]
    } elseif {$action eq "vcs.summary"} {
        vcs_summary_action [env_or_empty KDEBUG_TCL_DATABASE]
    } elseif {$action eq "power.resolve"} {
        power_resolve_action [env_or_empty KDEBUG_TCL_NAME] [env_or_empty KDEBUG_TCL_OBJECT_TYPE]
    } elseif {$action eq "power.list"} {
        power_list_action [env_or_empty KDEBUG_TCL_NAME] [env_or_empty KDEBUG_TCL_OBJECT_TYPE] [env_or_empty KDEBUG_TCL_MAX_ROWS]
    } elseif {$action eq "crdb.resolve"} {
        crdb_resolve_action [env_or_empty KDEBUG_TCL_CRDB] [env_or_empty KDEBUG_TCL_NAME] [env_or_empty KDEBUG_TCL_LEVEL]
    } elseif {$action eq "crdb.correlates"} {
        crdb_correlates_action [env_or_empty KDEBUG_TCL_CRDB] [env_or_empty KDEBUG_TCL_NAME] [env_or_empty KDEBUG_TCL_LEVEL] [env_or_empty KDEBUG_TCL_MAX_ROWS]
    } elseif {$action eq "transaction.writer.create"} {
        transaction_writer_action [env_or_empty KDEBUG_TCL_OUTPUT] [env_or_empty KDEBUG_TCL_OVERWRITE] [env_or_empty KDEBUG_TCL_UNIT] [env_or_empty KDEBUG_TCL_BEGIN_TIME] [env_or_empty KDEBUG_TCL_STREAM] [env_or_empty KDEBUG_TCL_TRANSACTION_PLAN] [env_or_empty KDEBUG_TCL_TAG_PLAN] [env_or_empty KDEBUG_TCL_RELATION_PLAN]
    } elseif {$action eq "fsdb.writer.create_scope"} {
        fsdb_writer_create_scope_action [env_or_empty KDEBUG_TCL_OUTPUT] [env_or_empty KDEBUG_TCL_OVERWRITE] [env_or_empty KDEBUG_TCL_UNIT] [env_or_empty KDEBUG_TCL_BEGIN_TIME] [env_or_empty KDEBUG_TCL_END_TIME_DELTA] [env_or_empty KDEBUG_TCL_OPERATION_PLAN]
    } else {
        fail_data "NOT_IMPLEMENTED" "Tcl NPI backend does not implement action: $action"
    }
}

if {[catch {main} err opts]} {
    if {[catch {dict get $opts -errorinfo} info]} {
        fail_data "TCL_NPI_ERROR" $err
    } else {
        fail_data "TCL_NPI_ERROR" "$err\n$info"
    }
}
if {[llength [info commands debExit]]} {
    debExit
} else {
    exit
}
