defmodule Goth.Token do
  @moduledoc """
  Functions for retrieving the token from the Google API.
  """

  @type t :: %__MODULE__{
          token: String.t(),
          type: String.t(),
          scope: String.t(),
          expires: non_neg_integer
          # TODO: do we still need these?
          # account: String.t()
          # sub: String.t() | nil
        }

  defstruct [:token, :type, :scope, :sub, :expires, :account]

  @default_url "https://www.googleapis.com/oauth2/v4/token"
  @default_scope "https://www.googleapis.com/auth/cloud-platform"

  @doc """
  Fetch the token from the Google API using the given `config`.

  Config may contain the following keys:

    * `:source` - One of:

      * `{:service_account, credentials, options}` - use a service account.

        `credentials` is a map and can contain the following keys:

          * `"private_key"`

          * `"client_email"`

          * `"token_uri"`

        `options` is a keywords list and can contain the following keys:

          * `:url` - the URL of the authentication service, defaults to:
            `"https://www.googleapis.com/oauth2/v4/token"`

          * `:scope` - the token scope, defaults to `#{inspect(@default_scope)}`

      * `{:refresh_token, credentials, options}` - use a refresh token.

        `credentials` is a map and can contain the following keys:

          * `"refresh_token"`

          * `"client_id"`

          * `"client_secret"`

        `options` is a keywords list and can contain the following keys:

          * `:url` - the URL of the authentication service, defaults to:
            `"https://www.googleapis.com/oauth2/v4/token"`

      * `{:metadata, options}` - use the Google metadata server.

        `options` is a keywords list and can contain the following keys:

          * `:account` - the name of the account to generate the token for, defaults to `"default"`

          * `:url` - the URL of the metadata server, defaults to `"http://metadata.google.internal"`

    * `:http_client` - HTTP client configuration, defaults to using `Goth.HTTPClient.Hackney`.
      See `Goth.HTTPClient` for more information.

  ## Examples

  ### Generate a token using a service account credentials file:

      iex> credentials = "credentials.json" |> File.read!() |> Jason.decode!()
      iex> Goth.Token.fetch(%{source: {:service_account, credentials, []}})
      {:ok, %Goth.Token{...}}

  You can generate a credentials file containing service account using `gcloud` utility like this:

      gcloud iam service-accounts keys create --key-file-type=json --iam-account=... credentials.json

  ## Retrieve the token using a refresh token:

      iex> credentials = "credentials.json" |> File.read!() |> Jason.decode!()
      iex> Goth.Token.fetch(%{source: {:refresh_token, credentials, []}})
      {:ok, %Goth.Token{...}}

  You can generate a credentials file containing refresh token using `gcloud` utility like this:

      gcloud auth application-default login

  ## Retrieve the token using the Google metadata server:

      iex> Goth.Token.fetch(%{source: {:metadata, []}})
      {:ok, %Goth.Token{...}}

  See [Storing and retrieving instance metadata](https://cloud.google.com/compute/docs/storing-retrieving-metadata)
  for more information on metadata server.
  """
  @doc since: "1.3.0"
  @spec fetch(map()) :: {:ok, t()} | {:error, Exception.t}
  def fetch(config) when is_map(config) do
    config =
      Map.put_new_lazy(config, :http_client, fn ->
        Goth.HTTPClient.init({Goth.HTTPClient.Hackney, []})
      end)

    case request(config) do
      {:ok, %{status: 200} = response} ->
        with {:ok, map} <- Jason.decode(response.body) do
          %{
            "access_token" => access_token,
            "expires_in" => expires_in,
            "token_type" => token_type
          } = map

          token = %__MODULE__{
            expires: System.system_time(:second) + expires_in,
            # TODO:
            scope: map["scope"],
            token: access_token,
            type: token_type
            # sub: ...,
            # account: ...
          }

          {:ok, token}
        end

      {:ok, response} ->
        message = """
        unexpected status #{response.status} from Google

        #{response.body}
        """

        {:error, RuntimeError.exception(message)}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp request(%{source: {:service_account, credentials, options}} = config)
       when is_map(credentials) and is_list(options) do
    url = Keyword.get(options, :url, @default_url)
    scope = Keyword.get(options, :scope, @default_scope)
    jwt = jwt(scope, credentials)
    headers = [{"content-type", "application/x-www-form-urlencoded"}]
    grant_type = "urn:ietf:params:oauth:grant-type:jwt-bearer"
    body = "grant_type=#{grant_type}&assertion=#{jwt}"
    Goth.HTTPClient.request(config.http_client, :post, url, headers, body, [])
  end

  defp request(%{source: {:refresh_token, credentials, options}} = config)
       when is_map(credentials) and is_list(options) do
    url = Keyword.get(options, :url, @default_url)
    headers = [{"Content-Type", "application/x-www-form-urlencoded"}]
    refresh_token = Map.fetch!(credentials, "refresh_token")
    client_id = Map.fetch!(credentials, "client_id")
    client_secret = Map.fetch!(credentials, "client_secret")

    body =
      URI.encode_query(
        grant_type: "refresh_token",
        refresh_token: refresh_token,
        client_id: client_id,
        client_secret: client_secret
      )

    Goth.HTTPClient.request(config.http_client, :post, url, headers, body, [])
  end

  defp request(%{source: {:metadata, options}} = config) when is_list(options) do
    account = Keyword.get(options, :account, "default")
    url = Keyword.get(options, :url, "http://metadata.google.internal")
    url = "#{url}/computeMetadata/v1/instance/service-accounts/#{account}/token"
    headers = [{"metadata-flavor", "Google"}]
    Goth.HTTPClient.request(config.http_client, :get, url, headers, "", [])
  end

  defp jwt(scope, %{
         "private_key" => private_key,
         "client_email" => client_email,
         "token_uri" => token_uri
       }) do
    jwk = JOSE.JWK.from_pem(private_key)
    header = %{"alg" => "RS256", "typ" => "JWT"}
    unix_time = System.system_time(:second)

    claim_set = %{
      "iss" => client_email,
      "scope" => scope,
      "aud" => token_uri,
      "exp" => unix_time + 3600,
      "iat" => unix_time
    }

    JOSE.JWT.sign(jwk, header, claim_set) |> JOSE.JWS.compact() |> elem(1)
  end

  # Everything below is deprecated.

  alias Goth.TokenStore
  alias Goth.Client

  # Get a `%Goth.Token{}` for a particular `scope`. `scope` can be a single
  # scope or multiple scopes joined by a space. See [OAuth 2.0 Scopes for Google APIs](https://developers.google.com/identity/protocols/googlescopes) for all available scopes.

  # `sub` needs to be specified if impersonation is used to prevent cache
  # leaking between users.

  # ## Example
  #     iex> Token.for_scope("https://www.googleapis.com/auth/pubsub")
  #     {:ok, %Goth.Token{expires: ..., token: "...", type: "..."} }
  @deprecated "Use Goth.fetch/1 instead"
  def for_scope(info, sub \\ nil)

  @spec for_scope(scope :: String.t(), sub :: String.t() | nil) :: {:ok, t} | {:error, any()}
  def for_scope(scope, sub) when is_binary(scope) do
    case TokenStore.find({:default, scope}, sub) do
      :error -> retrieve_and_store!({:default, scope}, sub)
      {:ok, token} -> {:ok, token}
    end
  end

  @spec for_scope(info :: {String.t() | atom(), String.t()}, sub :: String.t() | nil) ::
          {:ok, t} | {:error, any()}
  def for_scope({account, scope}, sub) do
    case TokenStore.find({account, scope}, sub) do
      :error -> retrieve_and_store!({account, scope}, sub)
      {:ok, token} -> {:ok, token}
    end
  end

  @doc false
  # Parse a successful JSON response from Google's token API and extract a `%Goth.Token{}`
  def from_response_json(scope, sub \\ nil, json)

  @spec from_response_json(String.t(), String.t() | nil, String.t()) :: t
  def from_response_json(scope, sub, json) when is_binary(scope) do
    {:ok, attrs} = json |> Jason.decode()

    %__MODULE__{
      token: attrs["access_token"],
      type: attrs["token_type"],
      scope: scope,
      sub: sub,
      expires: :os.system_time(:seconds) + attrs["expires_in"],
      account: :default
    }
  end

  @spec from_response_json(
          {atom() | String.t(), String.t()},
          String.t() | nil,
          String.t()
        ) :: t
  def from_response_json({account, scope}, sub, json) do
    {:ok, attrs} = json |> Jason.decode()

    %__MODULE__{
      token: attrs["access_token"],
      type: attrs["token_type"],
      scope: scope,
      sub: sub,
      expires: :os.system_time(:seconds) + attrs["expires_in"],
      account: account
    }
  end

  # Retrieve a new access token from the API. This is useful for expired tokens,
  # although `Goth` automatically handles refreshing tokens for you, so you should
  # rarely if ever actually need to call this method manually.
  @doc false
  @spec refresh!(t() | {any(), any()}) :: {:ok, t()}
  def refresh!(%__MODULE__{account: account, scope: scope, sub: sub}),
    do: refresh!({account, scope}, sub)

  def refresh!(%__MODULE__{account: account, scope: scope}), do: refresh!({account, scope})

  @doc false
  @spec refresh!({any(), any()}, any()) :: {:ok, t()}
  def refresh!({account, scope}, sub \\ nil), do: retrieve_and_store!({account, scope}, sub)

  @doc false
  def queue_for_refresh(%__MODULE__{} = token) do
    diff = token.expires - :os.system_time(:seconds)

    if diff < 10 do
      # just do it immediately
      Task.async(fn ->
        __MODULE__.refresh!(token)
      end)
    else
      :timer.apply_after((diff - 10) * 1000, __MODULE__, :refresh!, [token])
    end
  end

  defp retrieve_and_store!({account, scope}, sub) do
    Client.get_access_token({account, scope}, sub: sub)
    |> case do
      {:ok, token} ->
        TokenStore.store({account, scope}, sub, token)
        {:ok, token}

      other ->
        other
    end
  end
end
