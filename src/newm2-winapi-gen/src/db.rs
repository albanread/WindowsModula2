//! Read-only access to the windows_api SQLite database (schema v6).

use rusqlite::{Connection, OpenFlags};

pub struct TypeRow {
    pub type_id: i64,
    pub type_name: String,
    pub kind: String,
    pub abi_kind: Option<String>,
    /// Total layout size in bits (from winmd), used to recover a trailing
    /// fixed-array field's length (span = struct_size - field_offset).
    pub size_bits: Option<i64>,
}

pub struct ConstRow {
    pub name: String,
    pub value_kind: String,
    pub value_i64: Option<i64>,
    pub value_u64: Option<i64>, // stored as the raw bit pattern in a signed column
    pub value_f64: Option<f64>,
    pub value_text: Option<String>,
}

pub struct EnumMemberRow {
    pub enum_name: String,
    pub member_name: String,
    pub value_i64: i64,
    pub value_u64: i64,
    pub underlying_type: String,
    pub signedness: String,
    pub is_flags: bool,
}

pub struct StructFieldRow {
    pub struct_name: String,
    pub ordinal: i64,
    pub field_name: String,
    pub type_name: String,
    /// Byte offset of this field within the struct (from winmd), used to recover
    /// a fixed-array field's length (span = next_field_offset - this_offset).
    pub byte_offset: Option<i64>,
}

pub struct FunctionRow {
    pub function_id: i64,
    pub name: String,
    pub import_name: Option<String>,
    pub dll_name: Option<String>,
    pub return_type: Option<String>, // resolved qualified_name of the return type
}

pub struct ParamRow {
    pub ordinal: i64,
    pub name: Option<String>,
    pub type_name: Option<String>,
}

/// One method of an interface, in vtable order among the interface's OWN methods.
pub struct IfaceMethodRow {
    pub slot_index: i64,
    pub name: String,
    pub return_type: Option<String>,
    pub params: Vec<ParamRow>,
}

/// A COM interface and its own methods (loaded for a single namespace).
pub struct InterfaceRow {
    pub type_id: i64,
    pub name: String,
    pub qualified_name: String,
    pub iid: Option<String>,
    pub base_qualified_name: Option<String>,
    pub methods: Vec<IfaceMethodRow>,
}

/// A lightweight cross-namespace entry for every interface in the DB. Used to
/// compute absolute vtable ordinals (`@N`) by walking the INHERIT chain and to
/// resolve a base interface to its generated module + simple name.
pub struct IfaceIndexRow {
    pub qualified_name: String,
    pub namespace: String,
    pub name: String,
    pub base_qualified_name: Option<String>,
    pub own_method_count: i64,
}

pub fn open(path: &str) -> rusqlite::Result<Connection> {
    Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
}

/// All `Windows.Win32.*` namespaces present in the DB, ordered. These are the
/// flat C-style API namespaces (each with an `Apis` class); WinRT/COM-projection
/// namespaces are excluded.
pub fn list_win32_namespaces(conn: &Connection) -> rusqlite::Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT DISTINCT namespace_name FROM types
         WHERE namespace_name LIKE 'Windows.Win32.%' ORDER BY namespace_name",
    )?;
    let rows = stmt
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

pub fn load_types(conn: &Connection, ns: &str) -> rusqlite::Result<Vec<TypeRow>> {
    let mut stmt = conn.prepare(
        "SELECT type_id, type_name, kind, abi_kind, size_bits
         FROM types WHERE namespace_name = ?1 ORDER BY type_name",
    )?;
    let rows = stmt
        .query_map([ns], |r| {
            Ok(TypeRow {
                type_id: r.get(0)?,
                type_name: r.get(1)?,
                kind: r.get(2)?,
                abi_kind: r.get(3)?,
                size_bits: r.get(4)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

pub fn load_constants(conn: &Connection, ns: &str) -> rusqlite::Result<Vec<ConstRow>> {
    let mut stmt = conn.prepare(
        "SELECT constant_name, value_kind, value_i64, value_u64, value_f64, value_text
         FROM constants WHERE namespace_name = ?1 ORDER BY constant_name",
    )?;
    let rows = stmt
        .query_map([ns], |r| {
            Ok(ConstRow {
                name: r.get(0)?,
                value_kind: r.get(1)?,
                value_i64: r.get(2)?,
                value_u64: r.get(3)?,
                value_f64: r.get(4)?,
                value_text: r.get(5)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

pub fn load_enum_members(conn: &Connection, ns: &str) -> rusqlite::Result<Vec<EnumMemberRow>> {
    let mut stmt = conn.prepare(
        "SELECT t.type_name, em.member_name, em.value_i64, em.value_u64,
                em.underlying_type, em.signedness, em.is_flags
         FROM enum_members em JOIN types t ON t.type_id = em.enum_type_id
         WHERE t.namespace_name = ?1 ORDER BY t.type_name, em.ordinal",
    )?;
    let rows = stmt
        .query_map([ns], |r| {
            Ok(EnumMemberRow {
                enum_name: r.get(0)?,
                member_name: r.get(1)?,
                value_i64: r.get(2)?,
                value_u64: r.get(3)?,
                underlying_type: r.get(4)?,
                signedness: r.get(5)?,
                is_flags: r.get::<_, i64>(6)? != 0,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

pub fn load_functions(conn: &Connection, ns: &str) -> rusqlite::Result<Vec<FunctionRow>> {
    let mut stmt = conn.prepare(
        "SELECT f.function_id, f.function_name, f.import_name, f.dll_name, rt.qualified_name
         FROM functions f LEFT JOIN types rt ON rt.type_id = f.return_type_id
         WHERE f.namespace_name = ?1 ORDER BY f.function_name",
    )?;
    let rows = stmt
        .query_map([ns], |r| {
            Ok(FunctionRow {
                function_id: r.get(0)?,
                name: r.get(1)?,
                import_name: r.get(2)?,
                dll_name: r.get(3)?,
                return_type: r.get(4)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

pub fn load_params(conn: &Connection, function_id: i64) -> rusqlite::Result<Vec<ParamRow>> {
    let mut stmt = conn.prepare(
        "SELECT fp.ordinal, fp.param_name, pt.qualified_name
         FROM function_params fp LEFT JOIN types pt ON pt.type_id = fp.type_id
         WHERE fp.function_id = ?1 ORDER BY fp.ordinal",
    )?;
    let rows = stmt
        .query_map([function_id], |r| {
            Ok(ParamRow { ordinal: r.get(0)?, name: r.get(1)?, type_name: r.get(2)? })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

/// Load every COM interface (with a populated IID) in `ns`, ordered by name,
/// each with its own methods (ordered by slot_index) and per-method params
/// (ordered by ordinal). `iid IS NOT NULL` is the definitive "this is a COM
/// interface" signal — the iid is only populated during interface extraction —
/// and also sidesteps the re-import duplicate (the null-IID stub row). We do NOT
/// filter on `kind = 'interface'`: the winmd-importer's kind classifier
/// occasionally mislabels an interface (e.g. IDXGISwapChain came through as
/// 'reference'), but the iid + interface_methods are still extracted correctly.
pub fn load_interfaces(conn: &Connection, ns: &str) -> rusqlite::Result<Vec<InterfaceRow>> {
    let mut ifaces = {
        let mut stmt = conn.prepare(
            "SELECT type_id, type_name, qualified_name, iid, base_qualified_name
             FROM types
             WHERE namespace_name = ?1 AND iid IS NOT NULL
             ORDER BY type_name",
        )?;
        stmt.query_map([ns], |r| {
            Ok(InterfaceRow {
                type_id: r.get(0)?,
                name: r.get(1)?,
                qualified_name: r.get(2)?,
                iid: r.get(3)?,
                base_qualified_name: r.get(4)?,
                methods: Vec::new(),
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?
    };

    for iface in &mut ifaces {
        let mut methods = {
            let mut stmt = conn.prepare(
                "SELECT method_id, slot_index, method_name, return_type_name
                 FROM interface_methods
                 WHERE interface_type_id = ?1 ORDER BY slot_index",
            )?;
            stmt.query_map([iface.type_id], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    IfaceMethodRow {
                        slot_index: r.get(1)?,
                        name: r.get(2)?,
                        return_type: r.get(3)?,
                        params: Vec::new(),
                    },
                ))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?
        };
        for (method_id, method) in &mut methods {
            let mut stmt = conn.prepare(
                "SELECT ordinal, param_name, type_name
                 FROM interface_method_params
                 WHERE method_id = ?1 ORDER BY ordinal",
            )?;
            method.params = stmt
                .query_map([*method_id], |r| {
                    Ok(ParamRow { ordinal: r.get(0)?, name: r.get(1)?, type_name: r.get(2)? })
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
        }
        iface.methods = methods.into_iter().map(|(_, m)| m).collect();
    }

    Ok(ifaces)
}

/// Index every interface (across ALL namespaces) by qualified name, with its
/// base and own-method count — enough to compute absolute vtable ordinals and
/// resolve cross-namespace bases. Filtered to `iid IS NOT NULL` (skips the
/// duplicate stub rows).
pub fn load_interface_index(conn: &Connection) -> rusqlite::Result<Vec<IfaceIndexRow>> {
    let mut stmt = conn.prepare(
        "SELECT t.qualified_name, t.namespace_name, t.type_name, t.base_qualified_name,
                (SELECT COUNT(*) FROM interface_methods im WHERE im.interface_type_id = t.type_id)
         FROM types t
         WHERE t.iid IS NOT NULL
         ORDER BY t.qualified_name",
    )?;
    let rows = stmt
        .query_map([], |r| {
            Ok(IfaceIndexRow {
                qualified_name: r.get(0)?,
                namespace: r.get(1)?,
                name: r.get(2)?,
                base_qualified_name: r.get(3)?,
                own_method_count: r.get(4)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

pub fn load_struct_fields(conn: &Connection, ns: &str) -> rusqlite::Result<Vec<StructFieldRow>> {
    let mut stmt = conn.prepare(
        "SELECT t.type_name, sf.ordinal, sf.field_name, sf.type_name, sf.byte_offset
         FROM struct_fields sf JOIN types t ON t.type_id = sf.struct_type_id
         WHERE t.namespace_name = ?1 ORDER BY t.type_name, sf.ordinal",
    )?;
    let rows = stmt
        .query_map([ns], |r| {
            Ok(StructFieldRow {
                struct_name: r.get(0)?,
                ordinal: r.get(1)?,
                field_name: r.get(2)?,
                type_name: r.get(3)?,
                byte_offset: r.get(4)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}
