import argv
import filepath
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/application
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/pair
import gleam/result
import gleam/set
import gleam/string
import glint
import pevensie/auth.{
  type AuthDriver, type OneTimeTokenType, type Session, type UpdateField,
  type User, type UserCreate, type UserSearchFields, type UserUpdate, AuthDriver,
  Ignore, PasswordReset, Session, Set, User,
}
import pevensie/cache.{type CacheDriver, CacheDriver}
import pevensie/drivers
import pevensie/internal/encode.{type Encoder}
import pevensie/net.{type IpAddress}
import pog
import simplifile
import snag
import tempo.{type DateTime}
import tempo/date
import tempo/datetime
import tempo/instant
import tempo/month
import tempo/time

/// An IP version for a [`PostgresConfig`](#PostgresConfig).
pub type IpVersion {
  Ipv4
  Ipv6
}

/// Configuration for connecting to a Postgres database.
///
/// Use the [`default_config`](/pevensie/drivers/postgres.html#default_config)
/// function to get a default configuration for connecting to a local
/// Postgres database with sensible concurrency defaults.
///
/// ```gleam
/// import pevensie/drivers/postgres.{type PostgresConfig}
///
/// pub fn main() {
///   let config = PostgresConfig(
///     ..postgres.default_config(),
///     host: "db.pevensie.dev",
///     database: "my_database",
///   )
///   // ...
/// }
/// ```
pub type PostgresConfig {
  PostgresConfig(
    host: String,
    port: Int,
    database: String,
    user: String,
    password: Option(String),
    ssl: Bool,
    connection_parameters: List(#(String, String)),
    pool_size: Int,
    queue_target: Int,
    queue_interval: Int,
    idle_interval: Int,
    trace: Bool,
    ip_version: IpVersion,
    default_timeout: Int,
  )
}

/// The Postgres driver.
pub opaque type Postgres {
  Postgres(config: PostgresConfig, conn: Option(pog.Connection))
}

/// Errors that can occur when interacting with the Postgres driver.
/// Will probably be removed or changed - haven't decided on the final API yet.
pub type PostgresError {
  ConstraintViolated(message: String, constraint: String, detail: String)
  PostgresqlError(code: String, name: String, message: String)
  ConnectionUnavailable
}

/// Returns a default [`PostgresConfig`](#PostgresConfig) for connecting to a local
/// Postgres database.
///
/// Can also be used to provide sensible concurrency defaults for connecting
/// to a remote database.
///
/// ```gleam
/// import pevensie/drivers/postgres.{type PostgresConfig}
///
/// pub fn main() {
///   let config = PostgresConfig(
///     ..postgres.default_config(),
///     host: "db.pevensie.dev",
///     database: "my_database",
///   )
///   // ...
/// }
/// ```
pub fn default_config() -> PostgresConfig {
  PostgresConfig(
    host: "127.0.0.1",
    port: 5432,
    database: "postgres",
    user: "postgres",
    password: None,
    ssl: False,
    connection_parameters: [],
    pool_size: 1,
    queue_target: 50,
    queue_interval: 1000,
    idle_interval: 1000,
    trace: False,
    ip_version: Ipv4,
    default_timeout: 5000,
  )
}

fn postgres_config_to_pog_config(config: PostgresConfig) -> pog.Config {
  pog.Config(
    host: config.host,
    port: config.port,
    database: config.database,
    user: config.user,
    password: config.password,
    ssl: case config.ssl {
      True -> pog.SslVerified
      False -> pog.SslDisabled
    },
    connection_parameters: config.connection_parameters,
    pool_size: config.pool_size,
    queue_target: config.queue_target,
    queue_interval: config.queue_interval,
    idle_interval: config.idle_interval,
    trace: config.trace,
    ip_version: case config.ip_version {
      Ipv4 -> pog.Ipv4
      Ipv6 -> pog.Ipv6
    },
    rows_as_map: False,
    default_timeout: config.default_timeout,
  )
}

fn pog_query_error_to_postgres_error(err: pog.QueryError) -> PostgresError {
  case err {
    pog.PostgresqlError(code, name, message) ->
      PostgresqlError(code, name, message)
    pog.ConnectionUnavailable -> ConnectionUnavailable
    pog.ConstraintViolated(message, constraint, detail) ->
      ConstraintViolated(message, constraint, detail)
    _ ->
      panic as "pog Unexpected* error - should not occur if queries are written correctly"
  }
}

fn pog_query_error_to_pevensie_error(
  err: pog.QueryError,
  pevensie_error: fn(PostgresError) -> a,
) -> a {
  err
  |> pog_query_error_to_postgres_error
  |> pevensie_error
}

fn tempo_datetime_to_pog_timestamp(datetime: DateTime) -> pog.Timestamp {
  let date = datetime.get_date(datetime)
  let time = datetime.get_time(datetime)

  pog.Timestamp(
    date: pog.Date(
      year: date.get_year(date),
      month: date.get_month(date) |> month.to_int,
      day: date.get_day(date),
    ),
    time: pog.Time(
      hours: time.get_hour(time),
      minutes: time.get_minute(time),
      seconds: time.get_second(time),
      microseconds: time.get_microsecond(time),
    ),
  )
}

// ----- Auth Driver ----- //

/// Creates a new [`AuthDriver`](/pevensie/drivers/drivers.html#AuthDriver) for use with
/// the [`pevensie/auth.new`](/pevensie/auth.html#new) function.
///
/// ```gleam
/// import pevensie/drivers/postgres.{type PostgresConfig}
/// import pevensie/auth.{type PevensieAuth}
///
/// pub fn main() {
///   let config = PostgresConfig(
///     ..postgres.default_config(),
///     host: "db.pevensie.dev",
///     database: "my_database",
///   )
///   let driver = postgres.new_auth_driver(config)
///   let pevensie_auth = auth.new(
///     driver:,
///     user_metadata_decoder:,
///     user_metadata_encoder:,
///     cookie_key: "super secret signing key",
///   )
///   // ...
/// }
/// ```
pub fn new_auth_driver(
  config: PostgresConfig,
) -> AuthDriver(Postgres, PostgresError, user_metadata) {
  AuthDriver(
    driver: Postgres(config, None),
    connect:,
    disconnect:,
    list_users:,
    create_user:,
    update_user:,
    delete_user:,
    get_session:,
    create_session:,
    delete_session:,
    create_one_time_token:,
    validate_one_time_token:,
    use_one_time_token:,
    delete_one_time_token:,
  )
}

// Creates a new connection pool for the given Postgres driver.
fn connect(
  driver: Postgres,
) -> Result(Postgres, drivers.ConnectError(PostgresError)) {
  case driver {
    Postgres(config, None) -> {
      let conn =
        config
        |> postgres_config_to_pog_config
        |> pog.connect

      Ok(Postgres(config, Some(conn)))
    }
    Postgres(_, Some(_)) -> Error(drivers.AlreadyConnected)
  }
}

// Closes the connection pool for the given Postgres driver.
fn disconnect(
  driver: Postgres,
) -> Result(Postgres, drivers.DisconnectError(PostgresError)) {
  case driver {
    Postgres(config, Some(conn)) -> {
      let _ = pog.disconnect(conn)
      Ok(Postgres(config, None))
    }
    Postgres(_, None) -> Error(drivers.NotConnected)
  }
}

/// The SQL used to select fields from the `user` table.
pub const user_select_fields = "
  id::text,
  -- Convert timestamp fields to UNIX epoch microseconds
  (extract(epoch from created_at) * 1000000)::bigint as created_at,
  (extract(epoch from updated_at) * 1000000)::bigint as updated_at,
  (extract(epoch from deleted_at) * 1000000)::bigint as deleted_at,
  role,
  email,
  password_hash,
  (extract(epoch from email_confirmed_at) * 1000000)::bigint as email_confirmed_at,
  phone_number,
  (extract(epoch from phone_number_confirmed_at) * 1000000)::bigint as phone_number_confirmed_at,
  (extract(epoch from last_sign_in) * 1000000)::bigint as last_sign_in,
  app_metadata,
  user_metadata,
  (extract(epoch from banned_until) * 1000000)::bigint as banned_until
"

fn db_app_metadata_decoder() -> Decoder(auth.AppMetadata) {
  use data_string <- decode.then(decode.string)
  case json.parse(data_string, auth.app_metadata_decoder()) {
    Ok(data) -> decode.success(data)
    Error(_) -> decode.failure(auth.AppMetadata(dict.new()), "AppMetadata")
  }
}

/// We need an unsafe coerce as we don't want users to have to provide a zero value
/// for the user metadata field. Instead, we just unsafely coerce a `Nil` value to
/// the correct type.
@external(erlang, "pevensie_postgres_ffi", "unsafe_coerce")
fn unsafe_coerce_to_user_metadata(term: Nil) -> user_metadata

fn db_user_metadata_decoder(
  user_metadata_decoder: Decoder(user_metadata),
) -> Decoder(user_metadata) {
  let zero_value = unsafe_coerce_to_user_metadata(Nil)
  use data_string <- decode.then(decode.string)
  case json.parse(data_string, user_metadata_decoder) {
    Ok(data) -> decode.success(data)
    Error(_) -> decode.failure(zero_value, "UserMetadata")
  }
}

/// A decoder for the `user` table. Requires use of the
/// [`user_select_fields`](#user_select_fields) when querying.
pub fn user_decoder(
  user_metadata_decoder: Decoder(user_metadata),
) -> Decoder(User(user_metadata)) {
  use id <- decode.field(0, decode.string)
  use created_at_micro <- decode.field(1, decode.int)
  use updated_at_micro <- decode.field(2, decode.int)
  use deleted_at_micro <- decode.field(3, decode.optional(decode.int))
  use role <- decode.field(4, decode.optional(decode.string))
  use email <- decode.field(5, decode.string)
  use password_hash <- decode.field(6, decode.optional(decode.string))
  use email_confirmed_at_micro <- decode.field(7, decode.optional(decode.int))
  use phone_number <- decode.field(8, decode.optional(decode.string))
  use phone_number_confirmed_at_micro <- decode.field(
    9,
    decode.optional(decode.int),
  )
  use last_sign_in_micro <- decode.field(10, decode.optional(decode.int))
  use app_metadata <- decode.field(11, db_app_metadata_decoder())
  use user_metadata <- decode.field(
    12,
    db_user_metadata_decoder(user_metadata_decoder),
  )
  use banned_until_micro <- decode.field(13, decode.optional(decode.int))

  let created_at = datetime.from_unix_micro(created_at_micro)
  let updated_at = datetime.from_unix_micro(updated_at_micro)
  let deleted_at = option.map(deleted_at_micro, datetime.from_unix_micro)
  let email_confirmed_at =
    option.map(email_confirmed_at_micro, datetime.from_unix_micro)
  let phone_number_confirmed_at =
    option.map(phone_number_confirmed_at_micro, datetime.from_unix_micro)
  let last_sign_in = option.map(last_sign_in_micro, datetime.from_unix_micro)
  let banned_until = option.map(banned_until_micro, datetime.from_unix_micro)

  decode.success(User(
    id:,
    created_at:,
    updated_at:,
    deleted_at:,
    role:,
    email:,
    password_hash:,
    email_confirmed_at:,
    phone_number:,
    phone_number_confirmed_at:,
    last_sign_in:,
    app_metadata:,
    user_metadata:,
    banned_until:,
  ))
}

fn list_users(
  driver: Postgres,
  limit: Int,
  offset: Int,
  filters: UserSearchFields,
  using user_metadata_decoder: Decoder(user_metadata),
) -> Result(List(User(user_metadata)), auth.GetError(PostgresError)) {
  let assert Postgres(_, Some(conn)) = driver

  let filter_fields =
    [
      #("id", filters.id),
      #("email", filters.email),
      #("phone_number", filters.phone_number),
    ]
    |> list.filter(fn(field) { option.is_some(field.1) })
    |> list.index_map(fn(field, index) {
      #(
        // Filter SQL
        field.0 <> "::text like any($" <> int.to_string(index + 1) <> ")",
        // Filter values
        field.1 |> option.unwrap([]) |> pog.array(pog.text, _),
      )
    })

  let filter_sql =
    filter_fields
    |> list.map(pair.first)
    |> string.join(" or ")

  let sql = "
    select
      " <> user_select_fields <> "
    from pevensie.\"user\"
    where " <> filter_sql <> " and deleted_at is null
    limit " <> int.to_string(limit) <> "
    offset " <> int.to_string(offset)

  filter_fields
  |> list.fold(pog.query(sql), fn(query, field) {
    query
    |> pog.parameter(field.1)
  })
  |> pog.returning(user_decoder(user_metadata_decoder))
  |> pog.execute(conn)
  |> result.map(fn(response) { response.rows })
  |> result.map_error(fn(err) {
    err
    |> pog_query_error_to_postgres_error
    |> auth.GetDriverError
  })
}

fn create_user(
  driver: Postgres,
  user: UserCreate(user_metadata),
  decoder user_metadata_decoder: Decoder(user_metadata),
  encoder user_metadata_encoder: Encoder(user_metadata),
) -> Result(User(user_metadata), auth.CreateError(PostgresError)) {
  let assert Postgres(_, Some(conn)) = driver

  let sql = "
    insert into pevensie.\"user\" (
      role,
      email,
      password_hash,
      email_confirmed_at,
      phone_number,
      phone_number_confirmed_at,
      app_metadata,
      user_metadata
    ) values (
      $1,
      $2,
      $3,
      $4::timestamptz,
      $5,
      $6::timestamptz,
      $7::jsonb,
      $8::jsonb
    )
    returning
      " <> user_select_fields

  let query_result =
    pog.query(sql)
    |> pog.parameter(pog.nullable(pog.text, user.role))
    |> pog.parameter(pog.text(user.email))
    |> pog.parameter(pog.nullable(pog.text, user.password_hash))
    |> pog.parameter(pog.nullable(
      pog.timestamp,
      user.email_confirmed_at |> option.map(tempo_datetime_to_pog_timestamp),
    ))
    |> pog.parameter(pog.nullable(pog.text, user.phone_number))
    |> pog.parameter(pog.nullable(
      pog.timestamp,
      user.phone_number_confirmed_at
        |> option.map(tempo_datetime_to_pog_timestamp),
    ))
    |> pog.parameter(pog.text(
      auth.app_metadata_encoder(user.app_metadata) |> json.to_string,
    ))
    |> pog.parameter(pog.text(
      user_metadata_encoder(user.user_metadata) |> json.to_string,
    ))
    |> pog.returning(user_decoder(user_metadata_decoder))
    |> pog.execute(conn)
    |> result.map_error(pog_query_error_to_pevensie_error(
      _,
      auth.CreateDriverError,
    ))

  use response <- result.try(query_result)
  case response.rows {
    [user] -> Ok(user)
    [] -> Error(auth.CreatedTooFewRecords)
    [_, ..] -> Error(auth.CreatedTooManyRecords)
  }
}

fn update_field_to_sql(
  field: UpdateField(a),
  sql_type: fn(a) -> pog.Value,
) -> UpdateField(pog.Value) {
  case field {
    Set(value) -> Set(sql_type(value))
    Ignore -> Ignore
  }
}

fn update_user(
  driver: Postgres,
  field: String,
  value: String,
  user: UserUpdate(user_metadata),
  decoder user_metadata_decoder: Decoder(user_metadata),
  encoder user_metadata_encoder: Encoder(user_metadata),
) -> Result(User(user_metadata), auth.UpdateError(PostgresError)) {
  let assert Postgres(_, Some(conn)) = driver

  let optional_timestamp_to_pog = fn(timestamp: Option(DateTime)) -> pog.Value {
    timestamp
    |> option.map(tempo_datetime_to_pog_timestamp)
    |> pog.nullable(pog.timestamp, _)
  }

  let record_to_pog = fn(record: a, encoder: Encoder(a)) -> pog.Value {
    pog.text(encoder(record) |> json.to_string)
  }

  // Create a list of fields to update, filter by those that are set,
  // then create SQL to update those fields.
  let fields: List(#(String, UpdateField(pog.Value))) = [
    #("role", update_field_to_sql(user.role, pog.nullable(pog.text, _))),
    #("email", update_field_to_sql(user.email, pog.text)),
    #(
      "password_hash",
      update_field_to_sql(user.password_hash, pog.nullable(pog.text, _)),
    ),
    #(
      "email_confirmed_at",
      update_field_to_sql(user.email_confirmed_at, optional_timestamp_to_pog),
    ),
    #(
      "phone_number",
      update_field_to_sql(user.phone_number, pog.nullable(pog.text, _)),
    ),
    #(
      "phone_number_confirmed_at",
      update_field_to_sql(
        user.phone_number_confirmed_at,
        optional_timestamp_to_pog,
      ),
    ),
    #(
      "last_sign_in",
      update_field_to_sql(user.last_sign_in, optional_timestamp_to_pog),
    ),
    #(
      "app_metadata",
      update_field_to_sql(user.app_metadata, record_to_pog(
        _,
        auth.app_metadata_encoder,
      )),
    ),
    #(
      "user_metadata",
      update_field_to_sql(user.user_metadata, record_to_pog(
        _,
        user_metadata_encoder,
      )),
    ),
  ]

  let fields_to_update =
    fields
    |> list.filter_map(fn(field) {
      case field.1 {
        Set(value) -> Ok(#(field.0, value))
        Ignore -> Error(Nil)
      }
    })

  let field_setters =
    fields_to_update
    |> list.index_map(fn(field, index) {
      field.0 <> " = $" <> int.to_string(index + 1)
    })
    |> string.join(", ")

  // Add the updated_at field to the list of fields to update
  let field_setters = case field_setters {
    "" -> "updated_at = now()"
    _ -> field_setters <> ", updated_at = now()"
  }

  let update_values =
    fields_to_update
    |> list.map(pair.second)

  let sql = "
    update pevensie.\"user\"
    set " <> field_setters <> "
    where " <> field <> " = $" <> int.to_string(
      list.length(fields_to_update) + 1,
    ) <> " and deleted_at is null
    returning " <> user_select_fields

  let query_result =
    update_values
    |> list.fold(pog.query(sql), fn(query, value) {
      query
      |> pog.parameter(value)
    })
    |> pog.parameter(pog.text(value))
    |> pog.returning(user_decoder(user_metadata_decoder))
    |> pog.execute(conn)
    |> result.map_error(pog_query_error_to_pevensie_error(
      _,
      auth.UpdateDriverError,
    ))

  use response <- result.try(query_result)
  case response.rows {
    [user] -> Ok(user)
    [] -> Error(auth.UpdatedTooFewRecords)
    _ -> Error(auth.UpdatedTooManyRecords)
  }
}

fn delete_user(
  driver: Postgres,
  field: String,
  value: String,
  decoder user_metadata_decoder: Decoder(user_metadata),
) -> Result(User(user_metadata), auth.DeleteError(PostgresError)) {
  let assert Postgres(_, Some(conn)) = driver

  let sql = "
    update pevensie.\"user\"
    set deleted_at = now()
    where " <> field <> " = $1 and deleted_at is null
    returning " <> user_select_fields

  let query_result =
    pog.query(sql)
    |> pog.parameter(pog.text(value))
    |> pog.returning(user_decoder(user_metadata_decoder))
    |> pog.execute(conn)
    |> result.map_error(pog_query_error_to_pevensie_error(
      _,
      auth.DeleteDriverError,
    ))

  use response <- result.try(query_result)
  case response.rows {
    [user] -> Ok(user)
    [] -> Error(auth.DeletedTooFewRecords)
    _ -> Error(auth.DeletedTooManyRecords)
  }
}

/// The SQL used to select fields from the `session` table.
pub const session_select_fields = "
  id::text,
  user_id::text,
  (extract(epoch from created_at) * 1000000)::bigint as created_at,
  (extract(epoch from expires_at) * 1000000)::bigint as expires_at,
  host(ip)::text,
  user_agent
"

/// A decoder for the `session` table. Requires use of the
/// [`session_select_fields`](#session_select_fields) when querying.
pub fn session_decoder() -> Decoder(Session) {
  use id <- decode.field(0, decode.string)
  use user_id <- decode.field(1, decode.string)
  use created_at_micro <- decode.field(2, decode.int)
  use expires_at_micro <- decode.field(3, decode.optional(decode.int))
  use ip <- decode.field(4, decode.optional(net.ip_address_decoder()))
  use user_agent <- decode.field(5, decode.optional(decode.string))

  let created_at = datetime.from_unix_micro(created_at_micro)
  let expires_at = option.map(expires_at_micro, datetime.from_unix_micro)

  decode.success(Session(
    id:,
    created_at:,
    expires_at:,
    user_id:,
    ip:,
    user_agent:,
  ))
}

fn get_session(
  driver: Postgres,
  session_id: String,
  ip: Option(IpAddress),
  user_agent: Option(String),
) -> Result(Session, auth.GetError(PostgresError)) {
  let assert Postgres(_, Some(conn)) = driver

  // expires_at is true only if the expiration time is
  // set and has passed
  let sql = "
    select
      " <> session_select_fields <> ",
      (expires_at is not null and expires_at < now()) as expired
    from pevensie.\"session\"
    where id = $1
    "

  let additional_fields = [
    case ip {
      None -> #("ip is null", None)
      Some(_) -> #(
        "ip = $",
        Some(pog.nullable(pog.text, ip |> option.map(net.format_ip_address))),
      )
    },
    case user_agent {
      None -> #("user_agent is null", None)
      Some(_) -> #("user_agent = $", Some(pog.nullable(pog.text, user_agent)))
    },
  ]

  let #(sql, _) =
    // Start with counter at 2 as we already have one param for session ID
    list.fold(additional_fields, #(sql, 2), fn(sql_and_counter, field) {
      let #(sql, counter) = sql_and_counter
      case field {
        #(stmt, None) -> #(sql <> " and " <> stmt, counter)
        #(stmt, Some(_)) -> #(
          sql <> " and " <> stmt <> int.to_string(counter),
          counter + 1,
        )
      }
    })

  let query =
    pog.query(sql)
    |> pog.parameter(pog.text(session_id))

  let query =
    additional_fields
    |> list.fold(query, fn(query, field) {
      case field {
        #(_, Some(param)) -> query |> pog.parameter(param)
        _ -> query
      }
    })

  let query_result =
    query
    |> pog.returning({
      use session <- decode.then(session_decoder())
      use expired <- decode.field(6, decode.bool)
      decode.success(#(session, expired))
    })
    |> pog.execute(conn)
    |> result.map_error(pog_query_error_to_pevensie_error(
      _,
      auth.GetDriverError,
    ))

  use response <- result.try(query_result)
  case response.rows {
    // If no expiration is set, the value is valid forever
    [#(session, False)] -> Ok(session)
    // If the value has expired, return None and delete the session
    // in an async task
    [#(_, True)] -> {
      process.spawn_unlinked(fn() { delete_session(driver, session_id) })
      Error(auth.GotTooFewRecords)
    }
    [] -> Error(auth.GotTooFewRecords)
    _ -> Error(auth.GotTooManyRecords)
  }
}

// > Note: this may become part of the public driver API in the future
// fn delete_sessions_for_user(
//   driver: Postgres,
//   user_id: String,
//   except ignored_session_id: String,
// ) -> Result(Nil, auth.DeleteError(PostgresError)) {
//   let assert Postgres(_, Some(conn)) = driver
//
//   let sql =
//     "
//     delete from pevensie.\"session\"
//     where user_id = $1 and id != $2
//     returning id
//   "
//
//   pog.execute(
//     sql,
//     conn,
//     [pog.text(user_id), pog.text(ignored_session_id)],
//     dynamic.dynamic,
//   )
//   |> result.replace(Nil)
//   |> result.map_error(pog_query_error_to_pevensie_error(
//     _,
//     auth.DeleteDriverError,
//   ))
// }

fn create_session(
  driver: Postgres,
  user_id: String,
  ip: Option(IpAddress),
  user_agent: Option(String),
  ttl_seconds: Option(Int),
) -> Result(Session, auth.CreateError(PostgresError)) {
  let assert Postgres(_, Some(conn)) = driver

  let expires_at_sql = case ttl_seconds {
    None -> "null"
    Some(ttl_seconds) ->
      "now() + interval '" <> int.to_string(ttl_seconds) <> " seconds'"
  }

  // inet is a weird type and doesn't work with pog,
  // so we have to cast it to text.
  // This is fine because the `IpAddress` type is guaranteed
  // to be a valid IP address, so there's no chance of
  // SQL injection.
  let ip_string = case ip {
    None -> "null"
    Some(ip) -> "'" <> net.format_ip_address(ip) <> "'::inet"
  }

  let _ = net.parse_ip_address("127.0.0.1")

  let sql = "
    insert into pevensie.\"session\" (
      user_id,
      ip,
      user_agent,
      expires_at
    ) values (
      $1,
      " <> ip_string <> ",
      $2,
      " <> expires_at_sql <> "
    )
    returning
      " <> session_select_fields

  let query_result =
    pog.query(sql)
    |> pog.parameter(pog.text(user_id))
    |> pog.parameter(pog.nullable(pog.text, user_agent))
    |> pog.returning(session_decoder())
    |> pog.execute(conn)
    |> result.map_error(pog_query_error_to_pevensie_error(
      _,
      auth.CreateDriverError,
    ))

  use response <- result.try(query_result)
  case response.rows {
    [] -> Error(auth.CreatedTooFewRecords)
    [session] -> Ok(session)
    _ -> Error(auth.CreatedTooManyRecords)
  }
}

fn delete_session(
  driver: Postgres,
  session_id: String,
) -> Result(Nil, auth.DeleteError(PostgresError)) {
  let assert Postgres(_, Some(conn)) = driver

  let sql =
    "
    delete from pevensie.\"session\"
    where id = $1
    returning id
      "

  pog.query(sql)
  |> pog.parameter(pog.text(session_id))
  |> pog.execute(conn)
  |> result.replace(Nil)
  |> result.map_error(pog_query_error_to_pevensie_error(
    _,
    auth.DeleteDriverError,
  ))
}

fn one_time_token_type_to_prefix(token_type: OneTimeTokenType) -> String {
  case token_type {
    PasswordReset -> "pr"
  }
}

fn one_time_token_type_to_pg_enum(token_type: OneTimeTokenType) -> String {
  case token_type {
    PasswordReset -> "password-reset"
  }
}

fn create_one_time_token(
  driver: Postgres,
  user_id: String,
  token_type: OneTimeTokenType,
  ttl_seconds: Int,
) -> Result(String, auth.CreateError(PostgresError)) {
  let assert Postgres(_, Some(conn)) = driver

  let token =
    one_time_token_type_to_prefix(token_type)
    <> { crypto.strong_random_bytes(36) |> bit_array.base64_encode(True) }
  use token_hash <- result.try(
    encode.sha256_hash(token, token)
    |> result.replace_error(auth.CreateInternalError("Failed to hash token")),
  )

  let sql =
    "
  insert into pevensie.one_time_token (user_id, token_type, token_hash, expires_at)
  values ($1, $2, $3, now() + interval '$4 seconds')
    "

  pog.query(sql)
  |> pog.parameter(pog.text(user_id))
  |> pog.parameter(pog.text(one_time_token_type_to_pg_enum(token_type)))
  |> pog.parameter(pog.text(token_hash))
  |> pog.parameter(pog.text(int.to_string(ttl_seconds)))
  |> pog.execute(conn)
  |> result.replace(token)
  |> result.map_error(pog_query_error_to_pevensie_error(
    _,
    auth.CreateDriverError,
  ))
}

fn validate_one_time_token(
  driver: Postgres,
  user_id: String,
  token_type: OneTimeTokenType,
  token: String,
) -> Result(Nil, auth.GetError(PostgresError)) {
  let assert Postgres(_, Some(conn)) = driver

  use token_hash <- result.try(
    encode.sha256_hash(token, token)
    |> result.replace_error(auth.GetInternalError("Failed to hash token")),
  )

  let sql =
    "
  select id from pevensie.one_time_token
  where user_id = $1
    and token_type = $2
    and token_hash = $3
    and deleted_at is null
    and used_at is null
    and expires_at < now() -- USE THIS TO CREATE AN ERROR LATER?
    "

  pog.query(sql)
  |> pog.parameter(pog.text(user_id))
  |> pog.parameter(pog.text(one_time_token_type_to_pg_enum(token_type)))
  |> pog.parameter(pog.text(token_hash))
  |> pog.execute(conn)
  |> result.replace(Nil)
  |> result.map_error(pog_query_error_to_pevensie_error(_, auth.GetDriverError))
}

fn use_one_time_token(
  driver: Postgres,
  user_id: String,
  token_type: OneTimeTokenType,
  token: String,
) -> Result(Nil, auth.UpdateError(PostgresError)) {
  let assert Postgres(_, Some(conn)) = driver

  use token_hash <- result.try(
    encode.sha256_hash(token, token)
    |> result.replace_error(auth.UpdateInternalError("Failed to hash token")),
  )

  let sql =
    "
  update from pevensie.one_time_token
  set used_at = now()
  where user_id = $1
    and token_type = $2
    and token_hash = $3
    and deleted_at is null
    and used_at is null
    and expires_at < now() -- USE THIS TO CREATE AN ERROR LATER?
  returning id
    "

  pog.query(sql)
  |> pog.parameter(pog.text(user_id))
  |> pog.parameter(pog.text(one_time_token_type_to_pg_enum(token_type)))
  |> pog.parameter(pog.text(token_hash))
  |> pog.execute(conn)
  |> result.replace(Nil)
  |> result.map_error(pog_query_error_to_pevensie_error(
    _,
    auth.UpdateDriverError,
  ))
}

fn delete_one_time_token(
  driver: Postgres,
  user_id: String,
  token_type: OneTimeTokenType,
  token: String,
) -> Result(Nil, auth.DeleteError(PostgresError)) {
  let assert Postgres(_, Some(conn)) = driver

  use token_hash <- result.try(
    encode.sha256_hash(token, token)
    |> result.replace_error(auth.DeleteInternalError("Failed to hash token")),
  )

  let sql =
    "
  update from pevensie.one_time_token
  set deleted_at = now()
  where user_id = $1
    and token_type = $2
    and token_hash = $3
  returning id
    "

  pog.query(sql)
  |> pog.parameter(pog.text(user_id))
  |> pog.parameter(pog.text(one_time_token_type_to_pg_enum(token_type)))
  |> pog.parameter(pog.text(token_hash))
  |> pog.execute(conn)
  |> result.replace(Nil)
  |> result.map_error(pog_query_error_to_pevensie_error(
    _,
    auth.DeleteDriverError,
  ))
}

// ----- Cache Driver ----- //

/// Creates a new [`CacheDriver`](/pevensie/drivers/drivers.html#CacheDriver) for use with
/// the [`pevensie/cache.new`](/pevensie/cache.html#new) function.
///
/// ```gleam
/// import pevensie/drivers/postgres.{type PostgresConfig}
/// import pevensie/cache.{type PevensieCache}
///
/// pub fn main() {
///   let config = PostgresConfig(
///     ..postgres.default_config(),
///     host: "db.pevensie.dev",
///     database: "my_database",
///   )
///   let driver = postgres.new_cache_driver(config)
///   let pevensie_cache = cache.new(driver)
///   // ...
/// }
/// ```
pub fn new_cache_driver(
  config: PostgresConfig,
) -> CacheDriver(Postgres, PostgresError) {
  CacheDriver(
    driver: Postgres(config, None),
    connect: connect,
    disconnect: disconnect,
    set: set_in_cache,
    get: get_from_cache,
    delete: delete_from_cache,
  )
}

fn set_in_cache(
  driver: Postgres,
  resource_type: String,
  key: String,
  value: String,
  ttl_seconds: Option(Int),
) -> Result(Nil, cache.SetError(PostgresError)) {
  let assert Postgres(_, Some(conn)) = driver

  let expires_at_sql = case ttl_seconds {
    None -> "null"
    Some(ttl_seconds) ->
      "now() + interval '" <> int.to_string(ttl_seconds) <> " seconds'"
  }
  let sql = "
    insert into pevensie.\"cache\" (
      resource_type,
      key,
      value,
      expires_at
    ) values (
      $1,
      $2,
      $3,
      " <> expires_at_sql <> "
    )
    on conflict (resource_type, key) do update set value = EXCLUDED.value, expires_at = EXCLUDED.expires_at"

  pog.query(sql)
  |> pog.parameter(pog.text(resource_type))
  |> pog.parameter(pog.text(key))
  |> pog.parameter(pog.text(value))
  |> pog.execute(conn)
  |> result.replace(Nil)
  |> result.map_error(pog_query_error_to_pevensie_error(_, cache.SetDriverError))
}

fn get_from_cache(
  driver: Postgres,
  resource_type: String,
  key: String,
) -> Result(String, cache.GetError(PostgresError)) {
  let assert Postgres(_, Some(conn)) = driver

  let sql =
    "
    select
      value::text,
      -- Returns true only if the exporation time is
      -- set and has passed
      (expires_at is not null and expires_at < now()) as expired
    from pevensie.\"cache\"
    where resource_type = $1 and key = $2"

  let query_result =
    pog.query(sql)
    |> pog.parameter(pog.text(resource_type))
    |> pog.parameter(pog.text(key))
    |> pog.returning({
      use value <- decode.field(0, decode.string)
      use expired <- decode.field(1, decode.bool)
      decode.success(#(value, expired))
    })
    |> pog.execute(conn)
    |> result.map_error(pog_query_error_to_pevensie_error(
      _,
      cache.GetDriverError,
    ))

  use response <- result.try(query_result)
  case response.rows {
    // If no expiration is set, the value is valid forever
    [#(value, False)] -> {
      Ok(value)
    }
    // If the value has expired, return None and delete the key
    // in an async task
    [#(_, True)] -> {
      process.spawn_unlinked(fn() {
        delete_from_cache(driver, resource_type, key)
      })
      Error(cache.GotTooFewRecords)
    }
    [] -> Error(cache.GotTooFewRecords)
    _ -> Error(cache.GotTooManyRecords)
  }
}

fn delete_from_cache(
  driver: Postgres,
  resource_type: String,
  key: String,
) -> Result(Nil, cache.DeleteError(PostgresError)) {
  let assert Postgres(_, Some(conn)) = driver

  let sql =
    "
    delete from pevensie.\"cache\"
    where resource_type = $1 and key = $2"

  pog.query(sql)
  |> pog.parameter(pog.text(resource_type))
  |> pog.parameter(pog.text(key))
  |> pog.execute(conn)
  |> result.replace(Nil)
  |> result.map_error(pog_query_error_to_pevensie_error(
    _,
    cache.DeleteDriverError,
  ))
}

// ----- Migration function ----- //
fn add_error_context(error: String, context: String) {
  context <> ": " <> error
}

fn check_pevensie_schema_exists(tx: pog.Connection) -> Result(Bool, String) {
  let query_result =
    pog.query(
      "select schema_name from information_schema.schemata where schema_name = 'pevensie'",
    )
    |> pog.returning({
      use value <- decode.field(0, decode.string)
      decode.success(value)
    })
    |> pog.execute(tx)
    |> result.map_error(string.inspect)

  use response <- result.try(query_result)
  case response.rows {
    [_] -> Ok(True)
    [] -> Ok(False)
    _ -> Error("Too many rows")
  }
}

fn get_module_version(
  tx: pog.Connection,
  module: String,
) -> Result(Option(DateTime), String) {
  let query_result =
    pog.query(
      "select version::text from pevensie.module_version where module = '"
      <> module
      <> "' limit 1",
    )
    |> pog.returning({
      use datetime_string <- decode.field(0, decode.string)
      case datetime.from_string(datetime_string) {
        Ok(datetime) -> decode.success(datetime)
        Error(_) ->
          decode.failure(
            instant.now() |> instant.as_utc_datetime,
            "ModuleVersion",
          )
      }
    })
    |> pog.execute(tx)
    |> result.map_error(string.inspect)

  use response <- result.try(query_result)
  case response.rows {
    [] -> Ok(None)
    [version] -> Ok(Some(version))
    _ -> Error("Too many rows")
  }
}

fn get_migrations_for_module(module: String) -> Result(List(String), String) {
  use priv <- result.try(
    application.priv_directory("pevensie_postgres")
    |> result.replace_error("Couldn't get priv directory"),
  )

  let assert Ok(directory) =
    [priv, "migrations", module]
    |> list.reduce(filepath.join)

  simplifile.get_files(directory)
  |> result.map_error(fn(err) {
    err
    |> string.inspect
    |> add_error_context("Unable to get files in priv directory")
  })
}

fn version_from_filename(filename: String) -> DateTime {
  let assert Ok(filename) = filename |> filepath.split |> list.last
  let assert Ok(version_string) = filename |> string.split("_") |> list.first
  // gtempo requires an offset to be specified, so add one manually
  let assert Ok(version) =
    datetime.parse(version_string <> "Z", tempo.Custom("YYYYMMDDHHmmssZ"))
  version
}

fn get_migrations_to_apply_for_module(
  module: String,
  current_version: Option(DateTime),
) -> Result(Option(String), String) {
  use files <- result.try(
    get_migrations_for_module(module)
    |> result.map_error(add_error_context(
      _,
      "Failed to get migrations for '" <> module <> "' module",
    )),
  )

  let files_to_apply = case current_version {
    None -> files
    Some(current_version) -> {
      files
      |> list.filter(fn(file) {
        datetime.compare(version_from_filename(file), current_version)
        == order.Gt
      })
    }
  }

  // Check if there are files to apply
  use <- bool.guard(
    case files_to_apply {
      [] -> True
      _ -> False
    },
    Ok(None),
  )
  use migration_sql <- result.try(
    files_to_apply
    |> list.try_map(simplifile.read)
    |> result.map(string.join(_, "\n"))
    |> result.map_error(fn(err) {
      add_error_context(string.inspect(err), "Failed to read migrations")
    }),
  )

  let assert Ok(latest_migration) = list.last(files_to_apply)
  let new_version = version_from_filename(latest_migration)

  let new_version_sql = "insert into pevensie.module_version (module, version)
values ('" <> module <> "', timestamptz '" <> {
      new_version |> datetime.to_string
    } <> "')
on conflict (module)
do update set version = EXCLUDED.version;\n"

  Ok(Some(migration_sql <> "\n" <> new_version_sql))
}

fn apply_migrations_for_module(
  tx: pog.Connection,
  module: String,
  migration_sql: String,
) -> Result(Nil, String) {
  io.println_error("Applying migrations for module '" <> module <> "'")

  use last_char <- result.try(
    string.last(migration_sql |> string.trim_end)
    |> result.replace_error("Empty migration file"),
  )

  let sql = case last_char {
    ";" -> migration_sql
    _ -> migration_sql <> ";"
  }
  // pog doesn't allow executing multiple statements, so
  // wrap in a do block
  let sql = "do $pevensiemigration$ begin" <> sql <> " end;$pevensiemigration$"

  let query_result =
    pog.query(sql)
    |> pog.execute(tx)
    |> result.map_error(string.inspect)

  use _ <- result.try(query_result)
  io.println_error("ok.")
  Ok(Nil)
}

fn handle_module_migration(
  tx: pog.Connection,
  module: String,
  apply: Bool,
) -> Result(Nil, String) {
  io.print_error("Checking schema... ")
  use schema_exists <- result.try(
    check_pevensie_schema_exists(tx)
    |> result.map_error(add_error_context(
      _,
      "Unable to check if 'pevensie' schema exists",
    )),
  )
  io.println_error("ok.")

  io.print_error("Checking current version of '" <> module <> "' module... ")
  let version_result = case schema_exists {
    False -> Ok(None)
    True ->
      get_module_version(tx, module)
      |> result.map_error(add_error_context(
        _,
        "Unable to check '" <> module <> "' module version",
      ))
  }

  use current_version <- result.try(version_result)
  io.println_error(
    "ok. Current version: "
    <> current_version
    |> option.map(datetime.to_string)
    |> option.unwrap("none"),
  )

  io.print_error("Getting migrations for module '" <> module <> "'... ")
  use migration_sql <- result.try(
    get_migrations_to_apply_for_module(module, current_version)
    |> result.map_error(add_error_context(
      _,
      "Failed to get migrations to apply for '" <> module <> "'",
    )),
  )
  io.println_error("ok.")

  case migration_sql {
    None -> {
      io.println_error("No migrations to apply for module '" <> module <> "'\n")
      Ok(Nil)
    }
    Some(migration_sql) -> {
      case apply {
        True ->
          apply_migrations_for_module(tx, module, migration_sql)
          |> result.map_error(add_error_context(
            _,
            "Failed to apply migrations for '" <> module <> "'",
          ))
        False -> {
          io.println(migration_sql)
          Ok(Nil)
        }
      }
    }
  }
}

fn connection_string_flag() -> glint.Flag(String) {
  glint.string_flag("addr")
  |> glint.flag_help("The connection string for your Postgres database")
  |> glint.flag_default(
    "postgresql://postgres:postgres@localhost:5432/postgres",
  )
}

fn apply_flag() -> glint.Flag(Bool) {
  glint.bool_flag("apply")
  |> glint.flag_help("Apply migrations instead of just printing them")
  |> glint.flag_default(False)
}

fn migrate_command() {
  use <- glint.command_help(
    "Migrate Pevensie modules in your Postgres database",
  )
  use connection_string_arg <- glint.flag(connection_string_flag())
  use apply_flag <- glint.flag(apply_flag())
  use <- glint.unnamed_args(glint.MinArgs(1))

  use _, unnamed, flags <- glint.command()

  use connection_string <- result.try(connection_string_arg(flags))
  use apply <- result.try(apply_flag(flags))

  let deduped_modules =
    unnamed
    |> list.filter(fn(module) { module == "auth" || module == "cache" })
    |> set.from_list
    |> set.to_list

  use modules <- result.try(case deduped_modules {
    [] ->
      Error(
        snag.Snag(
          issue: "No valid modules specified. Valid modules: auth, cache",
          cause: ["no modules"],
        ),
      )
    modules -> Ok(modules)
  })

  use config <- result.try(
    pog.url_config(connection_string)
    |> result.replace_error(
      snag.Snag(issue: "Invalid Postgres connection string", cause: [
        "invalid connection string",
      ]),
    ),
  )
  let conn = pog.connect(config)
  let transaction_result =
    pog.transaction(conn, fn(tx) {
      use _ <- result.try(handle_module_migration(tx, "base", apply))

      let migration_result =
        modules
        |> list.try_each(handle_module_migration(tx, _, apply))

      use _ <- result.try(migration_result)

      case apply {
        True ->
          io.println_error(
            "\nSuccess! Applied migrations for modules: "
            <> modules |> string.join(","),
          )
        False -> Nil
      }
      Ok(Nil)
    })
  case transaction_result {
    Ok(_) -> Ok(Nil)
    Error(pog.TransactionRolledBack(msg)) ->
      Error(snag.Snag(issue: msg, cause: ["transaction rolled back"]))
    Error(pog.TransactionQueryError(err)) ->
      Error(
        snag.Snag(issue: "Query error: " <> string.inspect(err), cause: [
          "query error",
        ]),
      )
  }
}

pub fn main() {
  let cli =
    glint.new()
    |> glint.with_name("pevensie/drivers/postgres")
    |> glint.as_module
    |> glint.pretty_help(glint.default_pretty_help())
    |> glint.add(at: ["migrate"], do: migrate_command())

  use cli_result <- glint.run_and_handle(cli, argv.load().arguments)
  use errors <- result.map_error(cli_result)
  io.println_error("Command failed with an error: " <> errors.issue)
}
