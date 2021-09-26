defmodule Tesla.OpenApi3.Spec do
  alias Tesla.OpenApi3.{Prim, Union, Array, Object, Ref, Any}
  alias Tesla.OpenApi3.{Model, Operation, Param, Response}

  defstruct spec: %{}, models: %{}, operations: %{}
  @type t :: %__MODULE__{spec: map(), models: map(), operations: map()}

  @spec schema(map) :: Tesla.OpenApi3.schema()

  # Prim
  # TODO: Collapse null type into required/optional fields
  def schema(%{"type" => "null"}), do: %Prim{type: :null}
  def schema(%{"type" => "string"}), do: %Prim{type: :binary}
  def schema(%{"type" => "integer"}), do: %Prim{type: :integer}
  def schema(%{"type" => "number"}), do: %Prim{type: :number}
  def schema(%{"type" => "boolean"}), do: %Prim{type: :boolean}

  # Union
  def schema(%{"type" => types}) when is_list(types),
    do: collapse(%Union{of: Enum.map(types, &schema(%{"type" => &1}))})

  def schema(%{"items" => items}) when is_list(items),
    do: collapse(%Union{of: Enum.map(items, &schema/1)})

  def schema(%{"anyOf" => anyof}),
    do: collapse(%Union{of: Enum.map(anyof, &schema/1)})

  # Array
  def schema(%{"type" => "array", "items" => items}), do: %Array{of: schema(items)}
  def schema(%{"type" => "array"}), do: %Array{of: %Any{}}
  def schema(%{"items" => %{} = items}), do: %Array{of: schema(items)}

  # Object
  def schema(%{"properties" => %{} = props}),
    do: %Object{
      props:
        props
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.into(%{}, fn {key, val} -> {key, schema(val)} end)
    }

  def schema(%{"type" => "object", "allOf" => allof}), do: %Object{props: merge_props(allof)}
  def schema(%{"type" => "object"}), do: %Object{props: %{}}

  # Ref
  # v2
  def schema(%{"$ref" => "#/definitions/" <> name = ref}), do: %Ref{name: name, ref: ref}
  # v3
  def schema(%{"$ref" => "#/components/schemas/" <> name = ref}), do: %Ref{name: name, ref: ref}
  def schema(%{"$ref" => ref}), do: fetch(ref)

  # Any
  def schema(map) when map === %{}, do: %Any{}

  # Found in Slack spec
  def schema(%{"additionalProperties" => false}), do: %Any{}

  # wrapped
  def schema(%{"schema" => schema}), do: schema(schema)

  # TODO: HACK: Handle "content" => "..." correctly
  def schema(%{"content" => %{"application/json" => schema}}), do: schema(schema)

  def fetch(ref), do: schema(dereference(ref))

  defp merge_props(schemas) do
    Enum.reduce(schemas, %{}, fn schema, acc ->
      props =
        case schema(schema) do
          %Object{props: props} -> props
          %Ref{ref: ref} -> dereference(ref)
        end

      Map.merge(acc, props)
    end)
  end

  defp collapse(%Union{of: of}) do
    %Union{of: List.flatten(collapse(of))}
  end

  defp collapse(schemas) when is_list(schemas) do
    schemas
    |> Enum.reduce([[], [], []], fn
      %Object{} = x, [os, as, ps] -> [collapse(x, os), as, ps]
      %Array{} = x, [os, as, ps] -> [os, collapse(x, as), ps]
      %Prim{} = x, [os, as, ps] -> [os, as, collapse(x, ps)]
      %Union{} = x, [os, as, ps] -> collapse(x, [os, as, ps])
    end)
  end

  defp collapse(%Object{} = x, [%Object{} = y]) do
    props = Map.merge(x.props, y.props, fn _k, a, b -> collapse(%Union{of: [a, b]}) end)
    [%Object{props: props}]
  end

  defp collapse(%Array{of: x}, [%Array{of: y}]) do
    [%Array{of: collapse(%Union{of: [x, y]})}]
  end

  defp collapse(%Prim{} = x, prims) do
    Enum.uniq(prims ++ [x])
  end

  defp collapse(%Union{of: of}, [yos, yas, yps]) do
    [xos, xas, xps] = collapse(of)
    [collapse(xos, yos), collapse(xas, yas), collapse(xps, yps)]
  end

  defp collapse([x], ys) do
    collapse(x, ys)
  end

  defp collapse(xs, ys) when is_list(xs) and is_list(ys) do
    xs ++ ys
  end

  defp collapse(x, []) do
    [x]
  end

  defp dereference_params(params) do
    Enum.map(params, fn
      %{"$ref" => ref} -> dereference(ref)
      other -> other
    end)
  end

  defp dereference(ref) do
    spec = :erlang.get(:__tesla__spec)

    if spec == :undefined do
      raise "Spec not found under :__tesla__spec key"
    end

    case get_in(spec, compile_path(ref)) do
      nil -> raise "Reference #{ref} not found"
      item -> item
    end
  end

  defp compile_path("#/" <> ref) do
    ref
    |> String.split("/")
    |> Enum.map(&unescape/1)
  end

  defp unescape(s) do
    s
    |> String.replace("~0", "~")
    |> String.replace("~1", "/")
    |> URI.decode()
    |> key_or_index()
  end

  defp key_or_index(<<d, _::binary>> = key) when d in ?0..?9 do
    fn
      :get, data, next when is_list(data) -> data |> Enum.at(String.to_integer(key)) |> next.()
      :get, data, next when is_map(data) -> data |> Map.get(key) |> next.()
    end
  end

  defp key_or_index(key), do: key

  @spec read(binary) :: t()
  def read(file) do
    spec = file |> File.read!() |> Jason.decode!()

    load(spec)

    %__MODULE__{
      spec: spec,
      models: models(spec),
      operations: operations(spec)
    }
  end

  def load(spec), do: :erlang.put(:__tesla__spec, spec)

  # 2.x
  defp models(%{"definitions" => defs}), do: models(defs)
  # 3.x
  defp models(%{"components" => %{"schemas" => defs}}), do: models(defs)

  defp models(defs) when is_list(defs) or is_map(defs) do
    for {name, schema} <- defs, do: %Model{name: name, schema: schema(schema)}
  end

  def operations(spec) do
    for {path, methods} <- Map.get(spec, "paths", %{}),
        # match on "operationId" to filter out operations without id
        {method, %{"operationId" => id} = operation} <- methods do
      operation(id, method, path, operation)
    end
  end

  defp operation(id, method, path, operation) do
    params = dereference_params(operation["parameters"] || [])

    %Operation{
      id: id,
      summary: operation["summary"],
      description: operation["description"],
      method: method,
      path: path,
      path_params: params(params, "path"),
      query_params: params(params, "query"),
      body_params: params(params, "body"),
      request_body: request_body(operation),
      responses: responses(operation)
    }
  end

  defp params(params, kind) do
    for %{"name" => name, "in" => ^kind} = param <- params do
      %Param{name: name, schema: schema(param)}
    end
  end

  defp request_body(%{"requestBody" => body}), do: schema(body)
  defp request_body(_), do: nil

  defp responses(%{"responses" => responses}) do
    for {code, %{"schema" => schema}} <- responses do
      %Response{
        code: code_or_default(code),
        schema: schema(schema)
      }
    end
  end

  defp responses(_), do: []

  defp code_or_default("default"), do: :default
  defp code_or_default(code), do: String.to_integer(code)
end
