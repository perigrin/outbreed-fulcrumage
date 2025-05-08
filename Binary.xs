// ABOUTME: XS implementation for ECS binary serialization with DuckDB storage
// ABOUTME: Provides high-performance ECS operations with persistent DuckDB backend
#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"
#include <duckdb.h>
#include <string.h>
#include <stdio.h>

// ECS DuckDB connection type
typedef struct {
    duckdb_database db;
    duckdb_connection conn;
    int is_open;
    char* db_path;
} ecs_duckdb_handle;

// Forward declarations
static ecs_duckdb_handle* ecs_duckdb_connect(const char* path);
static void ecs_duckdb_disconnect(ecs_duckdb_handle* handle);
static int ecs_duckdb_execute(ecs_duckdb_handle* handle, const char* query);
static int ecs_duckdb_init_schema(ecs_duckdb_handle* handle, const char* world_name);

// Helper function to ensure we have a valid feature class object
static bool is_class_object(SV* sv) {
    return sv && SvROK(sv) &&
           SvTYPE(SvRV(sv)) == SVt_PVOBJ &&
           SvSTASH(SvRV(sv)) != NULL;
}

// Serialize a feature class object to binary data
static SV* serialize_object(SV* obj) {
    if (!is_class_object(obj))
        croak("Not a feature class object");

    SV* ref = SvRV(obj);

    // Get the package name
    HV* stash = SvSTASH(ref);
    if (!stash)
        croak("Object has no stash");

    const char* package = HvNAME(stash);
    if (!package)
        croak("Object's stash has no name");

    // Get fields and count
    SV** fields = ObjectFIELDS(ref);
    I32 field_count = ObjectMAXFIELD(ref) + 1;

    if (!fields || field_count < 0)
        croak("Could not access object fields");

    // Preallocate buffer
    STRLEN package_len = strlen(package);
    STRLEN initial_size = 1 + package_len + 1 + sizeof(field_count) + (field_count * 16);

    SV* buffer = newSV(initial_size);
    sv_setpvn(buffer, "", 0);

    // Format: type marker, package name, null terminator, field count, fields data
    sv_catpvn(buffer, "O", 1);
    sv_catpvn(buffer, package, package_len);
    sv_catpvn(buffer, "\0", 1);
    sv_catpvn(buffer, (char*)&field_count, sizeof(field_count));

    // Write each field
    I32 i;
    for (i = 0; i < field_count; i++) {
        SV* field = fields[i];

        if (!field || !SvOK(field)) {
            unsigned char type = 0;
            sv_catpvn(buffer, (char*)&type, 1);
            continue;
        }

        if (SvIOK(field)) {
            unsigned char type = 1;
            IV value = SvIV(field);
            sv_catpvn(buffer, (char*)&type, 1);
            sv_catpvn(buffer, (char*)&value, sizeof(value));
        }
        else if (SvNOK(field)) {
            unsigned char type = 2;
            NV value = SvNV(field);
            sv_catpvn(buffer, (char*)&type, 1);
            sv_catpvn(buffer, (char*)&value, sizeof(value));
        }
        else if (SvPOK(field)) {
            unsigned char type = 3;
            STRLEN len;
            const char* pv = SvPV_const(field, len);
            sv_catpvn(buffer, (char*)&type, 1);
            sv_catpvn(buffer, (char*)&len, sizeof(len));
            sv_catpvn(buffer, pv, len);
        }
        else {
            unsigned char type = 0;
            sv_catpvn(buffer, (char*)&type, 1);
        }
    }

    return buffer;
}

// Deserialize binary data into a class object
static SV* deserialize_object(SV* binary) {
    STRLEN data_len;
    const char* data = SvPV_const(binary, data_len);
    const char* cur = data;

    if (data_len < (1 + 1 + 1 + sizeof(I32)))
        croak("Invalid binary data: too short");

    if (*cur != 'O')
        croak("Invalid binary data: not an object");
    cur++;

    // Extract package name
    const char* package = cur;
    STRLEN package_len = 0;

    while (*cur && (size_t)(cur - data) < data_len) {
        cur++;
        package_len++;
    }

    if ((size_t)(cur - data) >= data_len)
        croak("Invalid binary data: missing null terminator");

    cur++;

    // Extract field count
    if ((size_t)(cur - data + sizeof(I32)) > data_len)
        croak("Invalid binary data: missing field count");

    I32 field_count = *(const I32*)cur;
    cur += sizeof(I32);

    if (field_count < 0 || field_count > 1000)
        croak("Invalid binary data: invalid field count %d", field_count);

    // Create class name
    char class_name[package_len + 1];
    strncpy(class_name, package, package_len);
    class_name[package_len] = '\0';

    // Create the stash
    HV* stash = gv_stashpvn(package, package_len, GV_ADD);
    if (!stash)
        croak("Could not find or create package '%.*s'", (int)package_len, package);

    // Call constructor
    dSP;
    ENTER;
    SAVETMPS;

    PUSHMARK(SP);
    XPUSHs(sv_2mortal(newSVpv(class_name, 0)));
    PUTBACK;

    int count = call_method("new", G_SCALAR);
    SPAGAIN;

    SV* obj = NULL;
    if (count != 1) {
        PUTBACK;
        FREETMPS;
        LEAVE;
        croak("Constructor for '%s' did not return an object", class_name);
    }

    obj = POPs;
    SvREFCNT_inc(obj);

    PUTBACK;
    FREETMPS;
    LEAVE;

    if (!is_class_object(obj)) {
        SvREFCNT_dec(obj);
        croak("Constructor for '%s' did not return a class object", class_name);
    }

    SV* ref = SvRV(obj);

    // Populate fields
    I32 obj_field_count = ObjectMAXFIELD(ref) + 1;
    if (obj_field_count != field_count) {
        warn("Warning: serialized object has %d fields but class '%s' has %d fields",
             field_count, class_name, obj_field_count);
        if (obj_field_count < field_count)
            field_count = obj_field_count;
    }

    I32 i;
    bool error = FALSE;
    for (i = 0; i < field_count && !error; i++) {
        if ((size_t)(cur - data) >= data_len) {
            warn("Binary data ended prematurely, only %d of %d fields processed", i, field_count);
            break;
        }

        unsigned char type = *cur++;
        SV* field = NULL;

        switch (type) {
            case 0: // Undefined
                field = newSV(0);
                break;

            case 1: // Integer
                if ((size_t)(cur - data + sizeof(IV)) <= data_len) {
                    IV value = *(const IV*)cur;
                    cur += sizeof(IV);
                    field = newSViv(value);
                } else {
                    error = TRUE;
                }
                break;

            case 2: // Double/float
                if ((size_t)(cur - data + sizeof(NV)) <= data_len) {
                    NV value = *(const NV*)cur;
                    cur += sizeof(NV);
                    field = newSVnv(value);
                } else {
                    error = TRUE;
                }
                break;

            case 3: // String
                if ((size_t)(cur - data + sizeof(STRLEN)) <= data_len) {
                    STRLEN len = *(const STRLEN*)cur;
                    cur += sizeof(STRLEN);

                    if ((size_t)(cur - data + len) <= data_len) {
                        field = newSVpvn(cur, len);
                        cur += len;
                    } else {
                        error = TRUE;
                    }
                } else {
                    error = TRUE;
                }
                break;

            default:
                warn("Unknown field type %d at position %d", (int)type, (int)(cur - data - 1));
                field = newSV(0);
                break;
        }

        if (field) {
            SV** fields = ObjectFIELDS(ref);
            if (fields && i < field_count) {
                if (fields[i])
                    SvREFCNT_dec(fields[i]);
                fields[i] = field;
            } else {
                SvREFCNT_dec(field);
                error = TRUE;
            }
        } else if (error) {
            break;
        }
    }

    if (error) {
        SvREFCNT_dec(obj);
        croak("Error deserializing field %d", i);
    }

    return obj;
}

// ECS DuckDB implementation
static ecs_duckdb_handle* ecs_duckdb_connect(const char* path) {
    ecs_duckdb_handle* handle = (ecs_duckdb_handle*)safemalloc(sizeof(ecs_duckdb_handle));
    if (!handle) {
        return NULL;
    }

    // Store path for later use
    size_t path_len = strlen(path);
    handle->db_path = (char*)safemalloc(path_len + 1);
    strcpy(handle->db_path, path);

    if (duckdb_open(path, &handle->db) != DuckDBSuccess) {
        Safefree(handle->db_path);
        Safefree(handle);
        return NULL;
    }

    if (duckdb_connect(handle->db, &handle->conn) != DuckDBSuccess) {
        duckdb_close(&handle->db);
        Safefree(handle->db_path);
        Safefree(handle);
        return NULL;
    }

    handle->is_open = 1;
    return handle;
}

static void ecs_duckdb_disconnect(ecs_duckdb_handle* handle) {
    if (!handle || !handle->is_open) {
        return;
    }

    duckdb_disconnect(&handle->conn);
    duckdb_close(&handle->db);
    handle->is_open = 0;
    
    if (handle->db_path) {
        Safefree(handle->db_path);
    }
    Safefree(handle);
}

static int ecs_duckdb_execute(ecs_duckdb_handle* handle, const char* query) {
    if (!handle || !handle->is_open) {
        return 0;
    }

    duckdb_result result;
    int success = (duckdb_query(handle->conn, query, &result) == DuckDBSuccess);
    duckdb_destroy_result(&result);
    return success;
}

static int ecs_duckdb_init_schema(ecs_duckdb_handle* handle, const char* world_name) {
    if (!handle || !handle->is_open) {
        return 0;
    }

    char query[2048];

    // Create entities table
    snprintf(query, sizeof(query),
        "CREATE TABLE IF NOT EXISTS %s_entities ("
        "entity_id INTEGER PRIMARY KEY, "
        "exists BOOLEAN DEFAULT TRUE, "
        "created_at BIGINT, "
        "deleted_at BIGINT DEFAULT NULL"
        ")", world_name);
    if (!ecs_duckdb_execute(handle, query)) return 0;

    // Create components table
    snprintf(query, sizeof(query),
        "CREATE TABLE IF NOT EXISTS %s_components ("
        "entity_id INTEGER, "
        "component_type TEXT, "
        "component_data BLOB, "
        "created_at BIGINT, "
        "PRIMARY KEY (entity_id, component_type)"
        ")", world_name);
    if (!ecs_duckdb_execute(handle, query)) return 0;

    // Create tags table
    snprintf(query, sizeof(query),
        "CREATE TABLE IF NOT EXISTS %s_tags ("
        "entity_id INTEGER, "
        "tag TEXT, "
        "created_at BIGINT, "
        "PRIMARY KEY (entity_id, tag)"
        ")", world_name);
    if (!ecs_duckdb_execute(handle, query)) return 0;

    // Create component_types registry
    snprintf(query, sizeof(query),
        "CREATE TABLE IF NOT EXISTS %s_component_types ("
        "type_name TEXT PRIMARY KEY, "
        "registered_at BIGINT"
        ")", world_name);
    if (!ecs_duckdb_execute(handle, query)) return 0;

    // Create indexes for performance
    snprintf(query, sizeof(query),
        "CREATE INDEX IF NOT EXISTS %s_entities_exists_idx ON %s_entities(exists)",
        world_name, world_name);
    if (!ecs_duckdb_execute(handle, query)) return 0;

    snprintf(query, sizeof(query),
        "CREATE INDEX IF NOT EXISTS %s_components_type_idx ON %s_components(component_type)",
        world_name, world_name);
    if (!ecs_duckdb_execute(handle, query)) return 0;

    snprintf(query, sizeof(query),
        "CREATE INDEX IF NOT EXISTS %s_tags_tag_idx ON %s_tags(tag)",
        world_name, world_name);
    if (!ecs_duckdb_execute(handle, query)) return 0;

    return 1;
}

MODULE = ECS::XS::Binary    PACKAGE = ECS::XS::Binary

BOOT:
{
    if (PERL_REVISION < 5 || (PERL_REVISION == 5 && PERL_VERSION < 40)) {
        croak("This module requires Perl 5.40 or later (found %d.%d.%d)",
              PERL_REVISION, PERL_VERSION, PERL_SUBVERSION);
    }
}

SV*
serialize(obj)
    SV* obj
    CODE:
        RETVAL = serialize_object(obj);
    OUTPUT:
        RETVAL

SV*
deserialize(binary)
    SV* binary
    CODE:
        RETVAL = deserialize_object(binary);
    OUTPUT:
        RETVAL

bool
is_class_object(sv)
    SV* sv
    CODE:
        RETVAL = is_class_object(sv);
    OUTPUT:
        RETVAL

I32
field_count(obj)
    SV* obj
    CODE:
        if (!obj || !SvROK(obj))
            croak("Not a valid object reference");

        if (!is_class_object(obj))
            croak("Not a feature class object");

        SV* ref = SvRV(obj);
        RETVAL = ObjectMAXFIELD(ref) + 1;
    OUTPUT:
        RETVAL

SV*
create_world(db_path, world_name = "ecs_world")
    const char* db_path
    const char* world_name
    CODE:
        // Connect to database and initialize schema
        ecs_duckdb_handle* handle = ecs_duckdb_connect(db_path);
        if (!handle) {
            croak("Failed to connect to database at %s", db_path);
        }

        if (!ecs_duckdb_init_schema(handle, world_name)) {
            ecs_duckdb_disconnect(handle);
            croak("Failed to initialize ECS schema in database");
        }

        ecs_duckdb_disconnect(handle);

        // Create World object
        SV* world;
        dSP;

        ENTER;
        SAVETMPS;

        PUSHMARK(SP);
        XPUSHs(sv_2mortal(newSVpv("ECS::XS::Binary::World", 0)));
        XPUSHs(sv_2mortal(newSVpv("db_path", 0)));
        XPUSHs(sv_2mortal(newSVpv(db_path, 0)));
        XPUSHs(sv_2mortal(newSVpv("world_name", 0)));
        XPUSHs(sv_2mortal(newSVpv(world_name, 0)));
        PUTBACK;

        int count = call_method("new", G_SCALAR);

        SPAGAIN;

        if (count != 1)
            croak("Failed to create world object");

        world = POPs;
        SvREFCNT_inc(world);

        PUTBACK;
        FREETMPS;
        LEAVE;

        RETVAL = world;
    OUTPUT:
        RETVAL

int
ecs_create_entity(db_path, world_name, entity_id, created_at)
    const char* db_path
    const char* world_name
    int entity_id
    long created_at
    CODE:
        ecs_duckdb_handle* handle = ecs_duckdb_connect(db_path);
        if (!handle) {
            croak("Failed to connect to database");
        }

        char query[512];
        snprintf(query, sizeof(query),
            "INSERT INTO %s_entities (entity_id, exists, created_at) VALUES (%d, TRUE, %ld)",
            world_name, entity_id, created_at);

        RETVAL = ecs_duckdb_execute(handle, query);
        ecs_duckdb_disconnect(handle);
    OUTPUT:
        RETVAL

int
ecs_destroy_entity(db_path, world_name, entity_id, deleted_at)
    const char* db_path
    const char* world_name
    int entity_id
    long deleted_at
    CODE:
        ecs_duckdb_handle* handle = ecs_duckdb_connect(db_path);
        if (!handle) {
            croak("Failed to connect to database");
        }

        char query[1024];
        
        // Mark entity as deleted
        snprintf(query, sizeof(query),
            "UPDATE %s_entities SET exists = FALSE, deleted_at = %ld WHERE entity_id = %d",
            world_name, deleted_at, entity_id);
        
        if (!ecs_duckdb_execute(handle, query)) {
            ecs_duckdb_disconnect(handle);
            RETVAL = 0;
            return;
        }

        // Remove all components
        snprintf(query, sizeof(query),
            "DELETE FROM %s_components WHERE entity_id = %d",
            world_name, entity_id);
        
        if (!ecs_duckdb_execute(handle, query)) {
            ecs_duckdb_disconnect(handle);
            RETVAL = 0;
            return;
        }

        // Remove all tags
        snprintf(query, sizeof(query),
            "DELETE FROM %s_tags WHERE entity_id = %d",
            world_name, entity_id);
        
        RETVAL = ecs_duckdb_execute(handle, query);
        ecs_duckdb_disconnect(handle);
    OUTPUT:
        RETVAL

int
ecs_entity_exists(db_path, world_name, entity_id)
    const char* db_path
    const char* world_name
    int entity_id
    CODE:
        ecs_duckdb_handle* handle = ecs_duckdb_connect(db_path);
        if (!handle) {
            croak("Failed to connect to database");
        }

        char query[512];
        snprintf(query, sizeof(query),
            "SELECT COUNT(*) FROM %s_entities WHERE entity_id = %d AND exists = TRUE",
            world_name, entity_id);

        duckdb_result result;
        if (duckdb_query(handle->conn, query, &result) != DuckDBSuccess) {
            ecs_duckdb_disconnect(handle);
            croak("Failed to check entity existence");
        }

        RETVAL = (duckdb_row_count(&result) > 0 && duckdb_value_int64(&result, 0, 0) > 0) ? 1 : 0;
        
        duckdb_destroy_result(&result);
        ecs_duckdb_disconnect(handle);
    OUTPUT:
        RETVAL

int
ecs_register_component_type(db_path, world_name, type_name, registered_at)
    const char* db_path
    const char* world_name
    const char* type_name
    long registered_at
    CODE:
        ecs_duckdb_handle* handle = ecs_duckdb_connect(db_path);
        if (!handle) {
            croak("Failed to connect to database");
        }

        char query[512];
        snprintf(query, sizeof(query),
            "INSERT OR IGNORE INTO %s_component_types (type_name, registered_at) VALUES ('%s', %ld)",
            world_name, type_name, registered_at);

        RETVAL = ecs_duckdb_execute(handle, query);
        ecs_duckdb_disconnect(handle);
    OUTPUT:
        RETVAL

int
ecs_add_component(db_path, world_name, entity_id, component_type, component_obj, created_at)
    const char* db_path
    const char* world_name
    int entity_id
    const char* component_type
    SV* component_obj
    long created_at
    CODE:
        if (!is_class_object(component_obj)) {
            croak("Component must be a class object");
        }

        ecs_duckdb_handle* handle = ecs_duckdb_connect(db_path);
        if (!handle) {
            croak("Failed to connect to database");
        }

        // Serialize the component
        SV* binary = serialize_object(component_obj);
        STRLEN binary_len;
        const char* binary_data = SvPV_const(binary, binary_len);

        // Prepare insert statement
        char query[512];
        snprintf(query, sizeof(query),
            "INSERT OR REPLACE INTO %s_components (entity_id, component_type, component_data, created_at) VALUES (?, ?, ?, ?)",
            world_name);

        duckdb_prepared_statement stmt;
        if (duckdb_prepare(handle->conn, query, &stmt) != DuckDBSuccess) {
            SvREFCNT_dec(binary);
            ecs_duckdb_disconnect(handle);
            croak("Failed to prepare component insert statement");
        }

        int success = 1;
        if (duckdb_bind_int32(stmt, 1, entity_id) != DuckDBSuccess ||
            duckdb_bind_varchar(stmt, 2, component_type) != DuckDBSuccess ||
            duckdb_bind_blob(stmt, 3, binary_data, binary_len) != DuckDBSuccess ||
            duckdb_bind_int64(stmt, 4, created_at) != DuckDBSuccess) {
            success = 0;
        }

        if (success && duckdb_execute_prepared(stmt, NULL) != DuckDBSuccess) {
            success = 0;
        }

        duckdb_destroy_prepare(&stmt);
        SvREFCNT_dec(binary);
        ecs_duckdb_disconnect(handle);

        RETVAL = success;
    OUTPUT:
        RETVAL

SV*
ecs_get_component(db_path, world_name, entity_id, component_type)
    const char* db_path
    const char* world_name
    int entity_id
    const char* component_type
    CODE:
        ecs_duckdb_handle* handle = ecs_duckdb_connect(db_path);
        if (!handle) {
            croak("Failed to connect to database");
        }

        char query[512];
        snprintf(query, sizeof(query),
            "SELECT component_data FROM %s_components WHERE entity_id = %d AND component_type = '%s'",
            world_name, entity_id, component_type);

        duckdb_result result;
        if (duckdb_query(handle->conn, query, &result) != DuckDBSuccess) {
            ecs_duckdb_disconnect(handle);
            croak("Failed to retrieve component");
        }

        if (duckdb_row_count(&result) == 0) {
            duckdb_destroy_result(&result);
            ecs_duckdb_disconnect(handle);
            RETVAL = &PL_sv_undef;
        } else {
            duckdb_blob blob_result = duckdb_value_blob(&result, 0, 0);
            const void* binary_data = blob_result.data;
            idx_t binary_len = blob_result.size;

            SV* binary = newSVpvn((const char*)binary_data, binary_len);
            RETVAL = deserialize_object(binary);
            SvREFCNT_dec(binary);

            duckdb_destroy_result(&result);
        }

        ecs_duckdb_disconnect(handle);
    OUTPUT:
        RETVAL

int
ecs_remove_component(db_path, world_name, entity_id, component_type)
    const char* db_path
    const char* world_name
    int entity_id
    const char* component_type
    CODE:
        ecs_duckdb_handle* handle = ecs_duckdb_connect(db_path);
        if (!handle) {
            croak("Failed to connect to database");
        }

        char query[512];
        snprintf(query, sizeof(query),
            "DELETE FROM %s_components WHERE entity_id = %d AND component_type = '%s'",
            world_name, entity_id, component_type);

        RETVAL = ecs_duckdb_execute(handle, query);
        ecs_duckdb_disconnect(handle);
    OUTPUT:
        RETVAL

int
ecs_has_component(db_path, world_name, entity_id, component_type)
    const char* db_path
    const char* world_name
    int entity_id
    const char* component_type
    CODE:
        ecs_duckdb_handle* handle = ecs_duckdb_connect(db_path);
        if (!handle) {
            croak("Failed to connect to database");
        }

        char query[512];
        snprintf(query, sizeof(query),
            "SELECT COUNT(*) FROM %s_components WHERE entity_id = %d AND component_type = '%s'",
            world_name, entity_id, component_type);

        duckdb_result result;
        if (duckdb_query(handle->conn, query, &result) != DuckDBSuccess) {
            ecs_duckdb_disconnect(handle);
            croak("Failed to check component existence");
        }

        RETVAL = (duckdb_row_count(&result) > 0 && duckdb_value_int64(&result, 0, 0) > 0) ? 1 : 0;
        
        duckdb_destroy_result(&result);
        ecs_duckdb_disconnect(handle);
    OUTPUT:
        RETVAL

int
ecs_add_tag(db_path, world_name, entity_id, tag, created_at)
    const char* db_path
    const char* world_name
    int entity_id
    const char* tag
    long created_at
    CODE:
        ecs_duckdb_handle* handle = ecs_duckdb_connect(db_path);
        if (!handle) {
            croak("Failed to connect to database");
        }

        char query[512];
        snprintf(query, sizeof(query),
            "INSERT OR IGNORE INTO %s_tags (entity_id, tag, created_at) VALUES (%d, '%s', %ld)",
            world_name, entity_id, tag, created_at);

        RETVAL = ecs_duckdb_execute(handle, query);
        ecs_duckdb_disconnect(handle);
    OUTPUT:
        RETVAL

int
ecs_remove_tag(db_path, world_name, entity_id, tag)
    const char* db_path
    const char* world_name
    int entity_id
    const char* tag
    CODE:
        ecs_duckdb_handle* handle = ecs_duckdb_connect(db_path);
        if (!handle) {
            croak("Failed to connect to database");
        }

        char query[512];
        snprintf(query, sizeof(query),
            "DELETE FROM %s_tags WHERE entity_id = %d AND tag = '%s'",
            world_name, entity_id, tag);

        RETVAL = ecs_duckdb_execute(handle, query);
        ecs_duckdb_disconnect(handle);
    OUTPUT:
        RETVAL

int
ecs_has_tag(db_path, world_name, entity_id, tag)
    const char* db_path
    const char* world_name
    int entity_id
    const char* tag
    CODE:
        ecs_duckdb_handle* handle = ecs_duckdb_connect(db_path);
        if (!handle) {
            croak("Failed to connect to database");
        }

        char query[512];
        snprintf(query, sizeof(query),
            "SELECT COUNT(*) FROM %s_tags WHERE entity_id = %d AND tag = '%s'",
            world_name, entity_id, tag);

        duckdb_result result;
        if (duckdb_query(handle->conn, query, &result) != DuckDBSuccess) {
            ecs_duckdb_disconnect(handle);
            croak("Failed to check tag existence");
        }

        RETVAL = (duckdb_row_count(&result) > 0 && duckdb_value_int64(&result, 0, 0) > 0) ? 1 : 0;
        
        duckdb_destroy_result(&result);
        ecs_duckdb_disconnect(handle);
    OUTPUT:
        RETVAL

void
ecs_query_entities_with_component(db_path, world_name, component_type)
    const char* db_path
    const char* world_name
    const char* component_type
    PPCODE:
        ecs_duckdb_handle* handle = ecs_duckdb_connect(db_path);
        if (!handle) {
            croak("Failed to connect to database");
        }

        char query[512];
        snprintf(query, sizeof(query),
            "SELECT DISTINCT c.entity_id FROM %s_components c "
            "JOIN %s_entities e ON c.entity_id = e.entity_id "
            "WHERE c.component_type = '%s' AND e.exists = TRUE "
            "ORDER BY c.entity_id",
            world_name, world_name, component_type);

        duckdb_result result;
        if (duckdb_query(handle->conn, query, &result) != DuckDBSuccess) {
            ecs_duckdb_disconnect(handle);
            croak("Failed to query entities with component");
        }

        idx_t row_count = duckdb_row_count(&result);
        if (row_count > 0) {
            EXTEND(SP, row_count);
            idx_t i;
            for (i = 0; i < row_count; i++) {
                int entity_id = duckdb_value_int32(&result, 0, i);
                PUSHs(sv_2mortal(newSViv(entity_id)));
            }
        }

        duckdb_destroy_result(&result);
        ecs_duckdb_disconnect(handle);

void
ecs_query_entities_with_tag(db_path, world_name, tag)
    const char* db_path
    const char* world_name
    const char* tag
    PPCODE:
        ecs_duckdb_handle* handle = ecs_duckdb_connect(db_path);
        if (!handle) {
            croak("Failed to connect to database");
        }

        char query[512];
        snprintf(query, sizeof(query),
            "SELECT DISTINCT t.entity_id FROM %s_tags t "
            "JOIN %s_entities e ON t.entity_id = e.entity_id "
            "WHERE t.tag = '%s' AND e.exists = TRUE "
            "ORDER BY t.entity_id",
            world_name, world_name, tag);

        duckdb_result result;
        if (duckdb_query(handle->conn, query, &result) != DuckDBSuccess) {
            ecs_duckdb_disconnect(handle);
            croak("Failed to query entities with tag");
        }

        idx_t row_count = duckdb_row_count(&result);
        if (row_count > 0) {
            EXTEND(SP, row_count);
            idx_t i;
            for (i = 0; i < row_count; i++) {
                int entity_id = duckdb_value_int32(&result, 0, i);
                PUSHs(sv_2mortal(newSViv(entity_id)));
            }
        }

        duckdb_destroy_result(&result);
        ecs_duckdb_disconnect(handle);