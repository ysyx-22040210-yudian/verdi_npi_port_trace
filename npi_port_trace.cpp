/*
 * npi_port_trace.cpp
 *
 * C++ port of npi_port_trace.tcl — same logic, same NPI L1 functions.
 *
 * CSV columns: inst_full_name, port_name, port_dir, role, signal_full_name
 *
 * Usage:
 *   ./npi_port_trace -elab <kdb.elab++ dir> -module <mod> [-ports p1,p2,...]
 */

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <set>

#include "npi.h"
#include "npi_hdl.h"
#include "npi_nl.h"
#include "npi_L1.h"

/* ------------------------------------------------------------------ */
/* Globals                                                              */
/* ------------------------------------------------------------------ */

static const char          *g_target_module = NULL;
static std::set<std::string> g_port_filter;

/* ------------------------------------------------------------------ */
/* Helpers                                                              */
/* ------------------------------------------------------------------ */

static const char *safe_str(const NPI_BYTE8 *s) {
    return s ? (const char *)s : "";
}

static std::string csv_field(const char *s) {
    if (!s || !s[0]) return "";
    std::string str(s);
    if (str.find_first_of(",\"\n") == std::string::npos)
        return str;
    std::string out = "\"";
    for (char c : str) {
        if (c == '"') out += '"';
        out += c;
    }
    out += '"';
    return out;
}

/*
 * hdl_to_name — mirrors TCL hdl_to_name:
 *   npi_nl_ut_get_hdl_info returns "type, fullname, (file:line)"
 *   take field [1] (index 1 after split on ',')
 */
static std::string hdl_to_name(npiNlHandle hdl) {
    const char *info = safe_str(npi_nl_ut_get_hdl_info(hdl));
    /* parse second comma-separated field */
    const char *p = strchr(info, ',');
    if (!p) return info;
    p++; /* skip comma */
    while (*p == ' ') p++;
    const char *end = strchr(p, ',');
    if (!end) return p;
    return std::string(p, end - p);
}

/* ------------------------------------------------------------------ */
/* process_instance — mirrors TCL proc process_instance               */
/* ------------------------------------------------------------------ */

static void process_instance(const char *inst_path,
                              const char *parent_path,
                              const char *instname) {
    /* npi_mod_inst_get_io: get ordered port list for this instance */
    nlHdlVec_t ioList;
    int n = npi_mod_inst_get_io((NPI_BYTE8 *)inst_path, ioList);
    if (n == 0 || ioList.empty()) {
        fprintf(stderr, "WARNING: no ports found for %s\n", inst_path);
        return;
    }

    for (auto ioHdl : ioList) {
        /* npi_ut_get_hdl_info: "npiIODecl, portname, {file:line}" */
        const char *info = safe_str(npi_ut_get_hdl_info(ioHdl));
        const char *p = strchr(info, ',');
        if (!p) continue;
        p++;
        while (*p == ' ') p++;
        const char *end = strchr(p, ',');
        std::string portname = end ? std::string(p, end - p) : std::string(p);
        if (portname.empty()) continue;

        /* port filter */
        if (!g_port_filter.empty() &&
            g_port_filter.find(portname) == g_port_filter.end())
            continue;

        /* direction from the ioDecl handle */
        NPI_INT32 dir_val = npi_nl_get(npiNlDirection, ioHdl);
        const char *dir_str = "unknown";
        if      (dir_val == npiInput)  dir_str = "input";
        else if (dir_val == npiOutput) dir_str = "output";
        else if (dir_val == npiInout)  dir_str = "inout";

        /* npi_nl_instport_handle_by_nl_name(parent, instname, portname) */
        npiNlHandle iph = npi_nl_instport_handle_by_nl_name(
            (NPI_BYTE8 *)parent_path,
            (NPI_BYTE8 *)instname,
            (NPI_BYTE8 *)portname.c_str());

        if (!iph) {
            printf("%s,%s,%s,driver,\n",
                   csv_field(inst_path).c_str(),
                   csv_field(portname.c_str()).c_str(),
                   dir_str);
            continue;
        }

        /* npi_nl_port_instport_2_net: get the net connected to this instport */
        npiNlHandle nh = npi_nl_port_instport_2_net(iph);
        if (!nh) {
            npi_nl_release_handle(iph);
            printf("%s,%s,%s,driver,\n",
                   csv_field(inst_path).c_str(),
                   csv_field(portname.c_str()).c_str(),
                   dir_str);
            continue;
        }

        /* get net full name from npi_nl_ut_get_hdl_info */
        std::string netname = hdl_to_name(nh);
        npi_nl_release_handle(nh);
        npi_nl_release_handle(iph);

        /* npi_nl_trace_driver(netname, sigList, assignCell=0, passMod=0) */
        nlHdlVec_t sigList;
        int r = npi_nl_trace_driver((NPI_BYTE8 *)netname.c_str(), sigList, 0, 0);
        if (r == 1 && !sigList.empty()) {
            for (auto hdl : sigList) {
                std::string sig = hdl_to_name(hdl);
                printf("%s,%s,%s,driver,%s\n",
                       csv_field(inst_path).c_str(),
                       csv_field(portname.c_str()).c_str(),
                       dir_str,
                       csv_field(sig.c_str()).c_str());
            }
        } else {
            printf("%s,%s,%s,driver,\n",
                   csv_field(inst_path).c_str(),
                   csv_field(portname.c_str()).c_str(),
                   dir_str);
        }

        /* npi_nl_trace_load(netname, loadList, assignCell=0, passMod=0) */
        nlHdlVec_t loadList;
        int r2 = npi_nl_trace_load((NPI_BYTE8 *)netname.c_str(), loadList, 0, 0);
        if (r2 == 1 && !loadList.empty()) {
            for (auto hdl : loadList) {
                std::string sig = hdl_to_name(hdl);
                printf("%s,%s,%s,load,%s\n",
                       csv_field(inst_path).c_str(),
                       csv_field(portname.c_str()).c_str(),
                       dir_str,
                       csv_field(sig.c_str()).c_str());
            }
        }
    }
}

/* ------------------------------------------------------------------ */
/* Argument parsing                                                     */
/* ------------------------------------------------------------------ */

static int parse_args(int argc, char **argv,
                      int *npi_argc, char ***npi_argv) {
    *npi_argv = (char **)malloc((argc + 8) * sizeof(char *));
    *npi_argc = 0;

    const char *elab_dir = NULL;
    bool has_lib  = false;
    bool has_path = false;

    (*npi_argv)[(*npi_argc)++] = argv[0];

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-module") == 0 && i + 1 < argc) {
            g_target_module = argv[++i];
        } else if (strcmp(argv[i], "-ports") == 0 && i + 1 < argc) {
            char *tok = strtok(argv[++i], ",");
            while (tok) {
                g_port_filter.insert(tok);
                tok = strtok(NULL, ",");
            }
        } else if (strcmp(argv[i], "-elab") == 0 && i + 1 < argc) {
            elab_dir = argv[++i];
        } else if (strcmp(argv[i], "-lib") == 0 && i + 1 < argc) {
            has_lib = true;
            (*npi_argv)[(*npi_argc)++] = argv[i];
            (*npi_argv)[(*npi_argc)++] = argv[++i];
        } else if (strcmp(argv[i], "-path") == 0 && i + 1 < argc) {
            has_path = true;
            (*npi_argv)[(*npi_argc)++] = argv[i];
            (*npi_argv)[(*npi_argc)++] = argv[++i];
        } else {
            (*npi_argv)[(*npi_argc)++] = argv[i];
        }
    }

    if (elab_dir && !has_lib && !has_path) {
        static std::string lib_path;
        lib_path = std::string(elab_dir);
        (*npi_argv)[(*npi_argc)++] = (char *)"-elab";
        (*npi_argv)[(*npi_argc)++] = (char *)lib_path.c_str();
    }

    return 0;
}

/* ------------------------------------------------------------------ */
/* main — mirrors TCL top-level                                        */
/* ------------------------------------------------------------------ */

int main(int argc, char **argv) {
    int    npi_argc;
    char **npi_argv;

    parse_args(argc, argv, &npi_argc, &npi_argv);

    if (!g_target_module) {
        fprintf(stderr,
            "Usage: %s -elab <kdb.elab++ dir> -module <mod> [-ports p1,p2,...]\n",
            argv[0]);
        free(npi_argv);
        return 1;
    }

    npi_init(npi_argc, npi_argv);

    int ret = npi_load_design(npi_argc, npi_argv);
    if (ret != 0)
        fprintf(stderr, "WARN: npi_load_design returned %d, continuing\n", ret);

    /* npi_find_inst_with_def_wildcard("", target_mod, hdlList) */
    nlHdlVec_t hdlList;
    int found = npi_find_inst_with_def_wildcard(
        (NPI_BYTE8 *)"",
        (NPI_BYTE8 *)g_target_module,
        hdlList);

    if (found == 0 || hdlList.empty()) {
        fprintf(stderr, "ERROR: no instances of module '%s' found\n", g_target_module);
        npi_end();
        free(npi_argv);
        return 1;
    }

    printf("inst_full_name,port_name,port_dir,role,signal_full_name\n");

    for (auto ih : hdlList) {
        /* npi_ut_get_hdl_info: "npiNlHierInst, full.path, ..." */
        const char *info = safe_str(npi_ut_get_hdl_info(ih));
        const char *p = strchr(info, ',');
        if (!p) continue;
        p++;
        while (*p == ' ') p++;
        const char *end = strchr(p, ',');
        std::string inst_path = end ? std::string(p, end - p) : std::string(p);
        if (inst_path.empty()) {
            fprintf(stderr, "WARNING: could not get path for instance handle, skipping\n");
            continue;
        }

        /* derive parent_path and instname from inst_path */
        size_t dot = inst_path.rfind('.');
        std::string instname, parent_path;
        if (dot == std::string::npos) {
            instname    = inst_path;
            parent_path = "";
        } else {
            instname    = inst_path.substr(dot + 1);
            parent_path = inst_path.substr(0, dot);
        }

        process_instance(inst_path.c_str(), parent_path.c_str(), instname.c_str());
    }

    npi_end();
    free(npi_argv);
    return 0;
}
