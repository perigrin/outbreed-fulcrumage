// XS implementation for field access and binary serialization
#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"

// Include DuckDB header if available
#ifdef HAVE_DUCKDB
#include "duckdb.h"
#endif

// Perl 5.40 class object APIs
// SVt_PVOBJ is a new SV type introduced in Perl 5.40 for class objects
// This should match the actual value in the running Perl
#ifndef SVt_PVOBJ
#define SVt_PVOBJ 17  // Value for Perl 5.40 class objects (based on Dump output)
#endif

// Define SVf_OBJECT if it's not already defined
#ifndef SVf_OBJECT
#define SVf_OBJECT 0x00001000  // This is a common value for OBJECT flag
#endif

// For internal use - we can't access the actual fields because we don't have
// access to the XPVOBJ structure definition from sv.h
// These offsets are determined empirically and may need adjustment
#define XPVOBJ_STASH_OFFSET 16     // Offset to STASH pointer
#define XPVOBJ_MAXFIELD_OFFSET 24  // Offset to MAXFIELD
#define XPVOBJ_FIELDS_OFFSET 32    // Offset to FIELDS pointer array

// ObjectFIELDS is a macro defined in sv.h - implement our own version
#ifndef ObjectFIELDS
#define ObjectFIELDS(sv) (*((SV***)((char*)(SvANY(sv)) + XPVOBJ_FIELDS_OFFSET)))
#endif

#ifndef ObjectMAXFIELD
#define ObjectMAXFIELD(sv) (*((SSize_t*)((char*)(SvANY(sv)) + XPVOBJ_MAXFIELD_OFFSET)))
#endif

// Implementation of ObjFIELDS_count as a function 
static I32 ObjFIELDS_count(SV* obj) {
    if (!obj || !SvOBJECT(obj))
        return -1;
    
    SSize_t maxfield = ObjectMAXFIELD(obj);
    
    // Just in case we got a strange value
    if (maxfield < 0 || maxfield > 1000)  // Arbitrary limit for sanity checking
        return -1;
        
    return (I32)maxfield + 1;
}

// Implementation of ObjFIELDS_alloc as a function
static bool ObjFIELDS_alloc(SV* obj, I32 count) {
    if (!obj || !SvOBJECT(obj) || count < 0)
        return FALSE;
    
    // Free existing fields if any
    SV** existing_fields = ObjectFIELDS(obj);
    if (existing_fields) {
        I32 existing_count = ObjFIELDS_count(obj);
        I32 i;
        for (i = 0; i < existing_count; i++) {
            if (existing_fields[i]) {
                SvREFCNT_dec(existing_fields[i]);
                existing_fields[i] = NULL;
            }
        }
        Safefree(existing_fields);
        ObjectFIELDS(obj) = NULL;
    }
    
    // Allocate field array
    SV** fields = (SV**)safemalloc(count * sizeof(SV*));
    if (!fields)
        return FALSE;
    
    // Initialize to NULL
    I32 i;
    for (i = 0; i < count; i++)
        fields[i] = NULL;
    
    ObjectFIELDS(obj) = fields;
    ObjectMAXFIELD(obj) = count - 1;
    return TRUE;
}

// Helper function to clean up a partially constructed object in case of error
static void cleanup_object(SV* obj) {
    if (!obj || !SvROK(obj))
        return;
    
    SV* ref = SvRV(obj);
    if (!ref || !SvOBJECT(ref))
        return;
    
    // Free field SVs if any
    SV** fields = ObjectFIELDS(ref);
    if (fields) {
        I32 count = ObjFIELDS_count(ref);
        I32 i;
        for (i = 0; i < count; i++) {
            if (fields[i]) {
                SvREFCNT_dec(fields[i]);
                fields[i] = NULL;
            }
        }
        Safefree(fields);
        ObjectFIELDS(ref) = NULL;
    }
    
    // Free the object
    SvREFCNT_dec(obj);
}

// Helper function to ensure we have a valid Perl 5.40 class object
static bool is_class_object(SV* sv) {
    if (!sv)
        return FALSE;
    
    // Must be a reference
    if (!SvROK(sv))
        return FALSE;
    
    // Get the referent
    SV* ref = SvRV(sv);
    if (!ref)
        return FALSE;
    
    // Check if it's blessed
    if (!SvOBJECT(ref))
        return FALSE;
        
    // Check if it has a stash
    HV* stash = SvSTASH(ref);
    if (!stash)
        return FALSE;
        
    // For this proof of concept, we'll accept any blessed reference as a class object
    // In production, we would need to verify it's actually a Perl 5.40 class
    
    return TRUE;
}

// Serialize a Perl 5.40 class object to binary data
static SV* serialize_object(SV* obj) {
    if (!is_class_object(obj))
        croak("Not a Perl 5.40 class object");
    
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
    I32 field_count = ObjFIELDS_count(ref);
    
    if (!fields || field_count < 0)
        croak("Could not access object fields");
    
    // Preallocate a reasonable size for the buffer (package + field count + basic overhead per field)
    // This helps reduce reallocation during buffer growth
    STRLEN package_len = strlen(package);
    STRLEN initial_size = 1 + package_len + 1 + sizeof(field_count) + (field_count * 16);
    
    // Start the output buffer
    SV* buffer = newSV(initial_size);
    sv_setpvn(buffer, "", 0);
    
    // Format:
    // - 1 byte type marker ('O' for object)
    // - package name (null terminated)
    // - number of fields (4 bytes)
    // - fields data (variable)
    
    // Write header
    sv_catpvn(buffer, "O", 1);                          // Object type marker
    sv_catpvn(buffer, package, package_len);            // Package name
    sv_catpvn(buffer, "\0", 1);                         // Null terminator
    sv_catpvn(buffer, (char*)&field_count, sizeof(field_count));  // Field count
    
    // Write each field
    I32 i;
    for (i = 0; i < field_count; i++) {
        SV* field = fields[i];
        
        if (!field || !SvOK(field)) {
            // Undefined field
            unsigned char type = 0;
            sv_catpvn(buffer, (char*)&type, 1);
            continue;
        }
        
        // Handle field based on its type
        if (SvIOK(field)) {
            // Integer
            unsigned char type = 1;
            IV value = SvIV(field);
            
            sv_catpvn(buffer, (char*)&type, 1);
            sv_catpvn(buffer, (char*)&value, sizeof(value));
        }
        else if (SvNOK(field)) {
            // Double/float
            unsigned char type = 2;
            NV value = SvNV(field);
            
            sv_catpvn(buffer, (char*)&type, 1);
            sv_catpvn(buffer, (char*)&value, sizeof(value));
        }
        else if (SvPOK(field)) {
            // String
            unsigned char type = 3;
            STRLEN len;
            const char* pv = SvPV_const(field, len);
            
            sv_catpvn(buffer, (char*)&type, 1);
            sv_catpvn(buffer, (char*)&len, sizeof(len));
            sv_catpvn(buffer, pv, len);
        }
        else {
            // Not a simple scalar type, store as undefined
            // No support for complex types in first draft
            unsigned char type = 0;
            sv_catpvn(buffer, (char*)&type, 1);
        }
    }
    
    return buffer;
}

// Deserialize binary data directly into a newly created class object for maximum performance
// Uses the constructor but avoids blessed hashrefs by working with Perl 5.40 class objects
static SV* deserialize_object(SV* binary) {
    STRLEN data_len;
    const char* data = SvPV_const(binary, data_len);
    const char* cur = data;
    
    // Validate minimal length (at least type marker, package name, null terminator, and field count)
    if (data_len < (1 + 1 + 1 + sizeof(I32)))
        croak("Invalid binary data: too short");
    
    // Check type marker
    if (*cur != 'O')
        croak("Invalid binary data: not an object");
    cur++;
    
    // Extract package name
    const char* package = cur;
    STRLEN package_len = 0;
    
    // Find null terminator and calculate package name length
    while (*cur && (size_t)(cur - data) < data_len) {
        cur++;
        package_len++;
    }
    
    if ((size_t)(cur - data) >= data_len)
        croak("Invalid binary data: missing null terminator");
    
    // Skip null terminator
    cur++;
    
    // Extract field count
    if ((size_t)(cur - data + sizeof(I32)) > data_len)
        croak("Invalid binary data: missing field count");
    
    I32 field_count = *(const I32*)cur;
    cur += sizeof(I32);
    
    if (field_count < 0 || field_count > 1000)  // Sanity check
        croak("Invalid binary data: invalid field count %d", field_count);
        
    // Create class name from package
    char class_name[package_len + 1];
    strncpy(class_name, package, package_len);
    class_name[package_len] = '\0';
    
    // Create the stash (package symbol table)
    HV* stash = gv_stashpvn(package, package_len, GV_ADD);
    if (!stash)
        croak("Could not find or create package '%.*s'", (int)package_len, package);
    
    // Read all the field data
    I32 i;
    bool error = FALSE;
    
    // Create a minimal array of parameter values to pass to our constructor
    // We'll create our object with just new() and then set fields
    dSP;
    
    ENTER;
    SAVETMPS;
    
    PUSHMARK(SP);
    XPUSHs(sv_2mortal(newSVpv(class_name, 0)));  // class name
    PUTBACK;
    
    // Call the constructor to get a proper class object
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
    SvREFCNT_inc(obj); // Prevent it from being freed when we FREETMPS
    
    PUTBACK;
    FREETMPS;
    LEAVE;
    
    // Now we have a properly constructed class object, let's get its referent
    if (!is_class_object(obj)) {
        SvREFCNT_dec(obj);
        croak("Constructor for '%s' did not return a class object", class_name);
    }
    
    SV* ref = SvRV(obj);
    
    // Verify we have the right field count
    I32 obj_field_count = ObjFIELDS_count(ref);
    if (obj_field_count != field_count) {
        // Warn but continue - this could happen if the class definition changed
        warn("Warning: serialized object has %d fields but class '%s' has %d fields", 
             field_count, class_name, obj_field_count);
        
        // Use the smaller count to avoid buffer overruns
        if (obj_field_count < field_count)
            field_count = obj_field_count;
    }
    
    // Now populate the fields
    for (i = 0; i < field_count && !error; i++) {
        // Check if we've reached the end of the data
        if ((size_t)(cur - data) >= data_len) {
            warn("Binary data ended prematurely, only %d of %d fields processed", i, field_count);
            break;
        }
        
        // Get field type
        unsigned char type = *cur++;
        
        // Create field based on type
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
                
            default: // Unknown type
                warn("Unknown field type %d at position %d", (int)type, (int)(cur - data - 1));
                field = newSV(0);
                break;
        }
        
        if (field) {
            // Assign the field directly to the object
            SV** fields = ObjectFIELDS(ref);
            if (fields && i < field_count) {
                // Release any existing value
                if (fields[i])
                    SvREFCNT_dec(fields[i]);
                    
                // Assign the new value
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

#ifdef HAVE_DUCKDB
/* DuckDB struct and helper functions */

/* DuckDB connection type for internal use */
typedef struct {
    duckdb_database db;
    duckdb_connection conn;
    int is_open;
} duckdb_handle;

/* Function prototypes for internal use */
static duckdb_handle* duckdb_internal_connect(const char* path);
static void duckdb_internal_disconnect(duckdb_handle* handle);
static int duckdb_internal_execute(duckdb_handle* handle, const char* query);
static int duckdb_internal_store_object(duckdb_handle* handle, const char* collection, SV* obj);

/* Implementation of internal functions */
static duckdb_handle* duckdb_internal_connect(const char* path) {
    duckdb_handle* handle = (duckdb_handle*)safemalloc(sizeof(duckdb_handle));
    if (!handle) {
        return NULL;
    }
    
    /* Initialize the database */
    if (duckdb_open(path, &handle->db) != DuckDBSuccess) {
        Safefree(handle);
        return NULL;
    }
    
    /* Create a connection */
    if (duckdb_connect(handle->db, &handle->conn) != DuckDBSuccess) {
        duckdb_close(&handle->db);
        Safefree(handle);
        return NULL;
    }
    
    handle->is_open = 1;
    return handle;
}

static void duckdb_internal_disconnect(duckdb_handle* handle) {
    if (!handle || !handle->is_open) {
        return;
    }
    
    duckdb_disconnect(&handle->conn);
    duckdb_close(&handle->db);
    handle->is_open = 0;
    Safefree(handle);
}

static int duckdb_internal_execute(duckdb_handle* handle, const char* query) {
    if (!handle || !handle->is_open) {
        return 0;
    }
    
    return (duckdb_query(handle->conn, query, NULL) == DuckDBSuccess);
}

static int duckdb_internal_store_object(duckdb_handle* handle, const char* collection, SV* obj) {
    if (!handle || !handle->is_open || !collection) {
        return 0;
    }
    
    /* Validate object */
    if (!is_class_object(obj)) {
        return 0;
    }
    
    /* Get class name */
    SV* ref = SvRV(obj);
    HV* stash = SvSTASH(ref);
    const char* class_name = HvNAME(stash);
    
    /* Serialize the object */
    SV* binary = serialize_object(obj);
    STRLEN binary_len;
    const char* binary_data = SvPV_const(binary, binary_len);
    
    /* Ensure the collection exists */
    char create_query[1024];
    sprintf(create_query, "CREATE TABLE IF NOT EXISTS %s (id INTEGER PRIMARY KEY, class_name TEXT, binary_data BLOB)", 
            collection);
    
    if (!duckdb_internal_execute(handle, create_query)) {
        SvREFCNT_dec(binary);
        return 0;
    }
    
    /* Prepare statement for insert */
    duckdb_prepared_statement stmt;
    char query[1024];
    sprintf(query, "INSERT INTO %s (class_name, binary_data) VALUES (?, ?)", collection);
    
    if (duckdb_prepare(handle->conn, query, &stmt) != DuckDBSuccess) {
        SvREFCNT_dec(binary);
        return 0;
    }
    
    /* Bind parameters */
    int success = 1;
    if (duckdb_bind_varchar(stmt, 1, class_name) != DuckDBSuccess ||
        duckdb_bind_blob(stmt, 2, binary_data, binary_len) != DuckDBSuccess) {
        success = 0;
    }
    
    /* Execute and clean up */
    if (success && duckdb_execute_prepared(stmt, NULL) != DuckDBSuccess) {
        success = 0;
    }
    
    duckdb_destroy_prepare(&stmt);
    SvREFCNT_dec(binary);
    
    return success;
}
#endif /* HAVE_DUCKDB */

MODULE = ECS::XS::Binary    PACKAGE = ECS::XS::Binary

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
        /* Validate input */
        if (!obj || !SvROK(obj))
            croak("Not a valid object reference");
            
        if (!is_class_object(obj))
            croak("Not a Perl 5.40 class object");
        
        /* Get the actual object */
        SV* ref = SvRV(obj);
        
        /* Get field count */
        I32 count = ObjFIELDS_count(ref);
        if (count < 0)
            croak("Invalid field count");
            
        RETVAL = count;
    OUTPUT:
        RETVAL

SV*
create_world()
    CODE:
        SV* world;
        dSP;
        
        ENTER;
        SAVETMPS;
        
        PUSHMARK(SP);
        XPUSHs(sv_2mortal(newSVpv("ECS::XS::Binary::World", 0)));
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

#ifdef HAVE_DUCKDB

SV*
store_object(db_path, collection, obj)
    const char* db_path
    const char* collection
    SV* obj
    CODE:
        /* Validate the object is a proper Perl 5.40 class object */
        if (!is_class_object(obj)) {
            croak("Not a Perl 5.40 class object");
        }
        
        /* Connect to the database */
        duckdb_handle* handle = duckdb_internal_connect(db_path);
        if (!handle) {
            croak("Failed to connect to database at %s", db_path);
        }
        
        /* Store the object */
        int success = duckdb_internal_store_object(handle, collection, obj);
        
        /* Disconnect */
        duckdb_internal_disconnect(handle);
        
        if (!success) {
            croak("Failed to store object in collection %s", collection);
        }
        
        /* Return true on success */
        RETVAL = newSViv(1);
    OUTPUT:
        RETVAL

void
retrieve_objects(db_path, collection, class_name, ...)
    const char* db_path
    const char* collection
    const char* class_name
    PPCODE:
        /* Connect to the database */
        duckdb_handle* handle = duckdb_internal_connect(db_path);
        if (!handle) {
            croak("Failed to connect to database at %s", db_path);
        }
        
        /* Optional WHERE clause */
        const char* where_clause = "";
        if (items > 3) {
            where_clause = SvPV_nolen(ST(3));
        }
        
        /* Build the query */
        char query[1024];
        sprintf(query, "SELECT binary_data FROM %s WHERE class_name = '%s' %s", 
                collection, class_name, where_clause);
        
        /* Execute the query */
        duckdb_result result;
        if (duckdb_query(handle->conn, query, &result) != DuckDBSuccess) {
            duckdb_internal_disconnect(handle);
            const char* error = duckdb_result_error(&result);
            croak("Failed to retrieve objects: %s", error ? error : "Unknown error");
        }
        
        /* Process each row */
        idx_t row_count = duckdb_row_count(&result);
        if (row_count > 0) {
            EXTEND(SP, row_count);
            
            idx_t i;
            for (i = 0; i < row_count; i++) {
                /* Get the binary data using correct DuckDB API functions */
                /* duckdb_blob contains both data and size fields */
                duckdb_blob blob_result = duckdb_value_blob(&result, 0, i);
                const void* binary_data = blob_result.data;
                idx_t binary_len = blob_result.size;
                
                /* Create a Perl scalar with the binary data */
                SV* binary = newSVpvn((const char*)binary_data, binary_len);
                
                /* Deserialize to object */
                SV* obj = deserialize_object(binary);
                
                /* Add to the result stack */
                PUSHs(sv_2mortal(obj));
                
                /* Free the temporary binary value */
                SvREFCNT_dec(binary);
            }
        }
        
        /* Clean up */
        duckdb_destroy_result(&result);
        duckdb_internal_disconnect(handle);

void
delete_objects(db_path, collection, class_name, ...)
    const char* db_path
    const char* collection
    const char* class_name
    CODE:
        /* Connect to the database */
        duckdb_handle* handle = duckdb_internal_connect(db_path);
        if (!handle) {
            croak("Failed to connect to database at %s", db_path);
        }
        
        /* Optional WHERE clause */
        const char* where_clause = "";
        if (items > 3) {
            where_clause = SvPV_nolen(ST(3));
        }
        
        /* Build the query */
        char query[1024];
        sprintf(query, "DELETE FROM %s WHERE class_name = '%s' %s", 
                collection, class_name, where_clause);
        
        /* Execute the query */
        if (!duckdb_internal_execute(handle, query)) {
            duckdb_internal_disconnect(handle);
            croak("Failed to delete objects");
        }
        
        duckdb_internal_disconnect(handle);

#endif /* HAVE_DUCKDB */