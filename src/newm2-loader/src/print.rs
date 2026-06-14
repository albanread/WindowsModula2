//! Pretty-printer for `newm2 dump-module-graph`.

use crate::graph::ModuleGraph;

pub fn format_graph(g: &ModuleGraph) -> String {
    let mut buf = String::new();
    buf.push_str("ModuleGraph\n");
    buf.push_str(&format!("  modules: {}\n", g.modules.len()));
    buf.push_str("  topo:");
    for (i, id) in g.topo_order.iter().enumerate() {
        if i > 0 {
            buf.push(',');
        }
        buf.push(' ');
        buf.push_str(&g.modules[id.0].name);
    }
    buf.push('\n');
    for id in &g.topo_order {
        let m = &g.modules[id.0];
        let intrinsic = if m.is_intrinsic { " (intrinsic)" } else { "" };
        buf.push_str(&format!("module {}{intrinsic}\n", m.name));
        if let Some(p) = &m.def_path {
            buf.push_str(&format!("  def: {}\n", relative(p)));
        }
        if let Some(p) = &m.impl_path {
            buf.push_str(&format!("  impl: {}\n", relative(p)));
        }
        if let Some(h) = &m.def_hash {
            buf.push_str(&format!("  def-hash: {h}\n"));
        }
        if m.imports.is_empty() {
            buf.push_str("  imports: (none)\n");
        } else {
            let names: Vec<&str> =
                m.imports.iter().map(|i| g.modules[i.0].name.as_str()).collect();
            buf.push_str(&format!("  imports: {}\n", names.join(", ")));
        }
        if !m.local_modules.is_empty() {
            buf.push_str(&format!(
                "  local-modules: {}\n",
                m.local_modules.join(", ")
            ));
        }
    }
    buf
}

/// Render a path so dump output is stable across machines: collapse
/// to "<basename>/<filename>" if the path has at least one component.
/// (This avoids absolute-path drift while still being informative.)
fn relative(p: &std::path::Path) -> String {
    let mut comps: Vec<&str> =
        p.components().filter_map(|c| c.as_os_str().to_str()).collect();
    if comps.len() <= 2 {
        return p.display().to_string();
    }
    let tail: Vec<&str> = comps.split_off(comps.len() - 2);
    tail.join("/")
}
