defmodule Tesla.OpenApi.Spec do
  alias Tesla.OpenApi.{Prim, Union, Array, Object, Ref, Any}
  alias Tesla.OpenApi.{Model, Operation, Param, Response}
  alias Tesla.OpenApi.Context

  defstruct info: %{},
            host: nil,
            base_path: nil,
            schemes: [],
            consumes: [],
            models: [],
            operations: []

  @type t :: %__MODULE__{
          info: map(),
          host: binary,
          base_path: binary,
          schemes: [binary],
          consumes: [binary],
          models: [Model.t()],
          operations: [Operation.t()]
        }

  @spec schema(map) :: Tesla.OpenApi.schema()

  # Wrapped
  def schema(%{"schema" => schema}), do: schema(schema)

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

  def schema(%{"anyOf" => anyof}), do: collapse(%Union{of: Enum.map(anyof, &schema/1)})
  def schema(%{"oneOf" => oneof}), do: collapse(%Union{of: Enum.map(oneof, &schema/1)})

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

  def schema(%{"allOf" => [one]}), do: schema(one)
  def schema(%{"allOf" => allof}), do: merge(Enum.map(allof, &schema/1))
  def schema(%{"type" => "object"}), do: %Object{props: %{}}

  # Ref
  # v2
  def schema(%{"$ref" => "#/definitions/" <> name = ref}), do: %Ref{name: name, ref: ref}
  # v3
  def schema(%{"$ref" => "#/components/schemas/" <> name = ref}), do: %Ref{name: name, ref: ref}
  def schema(%{"$ref" => ref}), do: fetch(ref)

  # Any
  def schema(map) when map === %{}, do: %Any{}

  # TODO: HACK: Handle "content" => "..." correctly
  def schema(%{"content" => %{"application/json" => schema}}), do: schema(schema)
  def schema(%{"content" => %{"application/octet-stream" => schema}}), do: schema(schema)
  def schema(%{"content" => %{"application/x-www-form-urlencoded" => schema}}), do: schema(schema)

  def schema(%{}), do: %Any{}

  def fetch(ref), do: schema(dereference(ref))

  defp merge(schemas) do
    case Enum.reject(schemas, &match?(%Any{}, &1)) do
      [one] ->
        one

      schemas ->
        cond do
          Enum.all?(schemas, fn
            %Object{} -> true
            %Ref{} -> true
            _ -> false
          end) ->
            %Object{props: merge_props(schemas)}
        end
    end
  end

  defp merge_props(schemas) do
    Enum.reduce(schemas, %{}, fn schema, acc ->
      Map.merge(acc, extract_props(schema))
    end)
  end

  defp extract_props(%Object{props: props}), do: props
  defp extract_props(%Ref{ref: ref}), do: extract_props(fetch(ref))

  defp collapse(%Union{of: of}) do
    case List.flatten(collapse(of)) do
      [one] -> one
      more -> %Union{of: more}
    end
  end

  defp collapse(schemas) when is_list(schemas) do
    schemas
    |> Enum.reduce([[], [], []], fn
      %Object{} = x, [os, as, ps] -> [collapse(x, os), as, ps]
      %Array{} = x, [os, as, ps] -> [os, collapse(x, as), ps]
      %Union{} = x, [os, as, ps] -> collapse(x, [os, as, ps])
      x, [os, as, ps] -> [os, as, collapse(x, ps)]
    end)
  end

  defp collapse(%Object{} = x, [%Object{} = y]) do
    props = Map.merge(x.props, y.props, fn _k, a, b -> collapse(%Union{of: [a, b]}) end)
    [%Object{props: props}]
  end

  defp collapse(%Array{of: x}, [%Array{of: y}]) do
    [%Array{of: collapse(%Union{of: [x, y]})}]
  end

  defp collapse(%Union{of: of}, [yos, yas, yps]) do
    [xos, xas, xps] = collapse(of)
    [collapse(xos, yos), collapse(xas, yas), collapse(xps, yps)]
  end

  defp collapse(%{} = x, prims) do
    Enum.uniq(prims ++ [x])
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
    case get_in(Context.get_spec(), compile_path(ref)) do
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

  @spec new(map()) :: t()
  def new(spec) do
    %__MODULE__{
      host: spec["host"] || "",
      base_path: spec["basePath"] || "",
      schemes: spec["schemes"] || [],
      consumes: spec["consumes"] || [],
      info: info(spec),
      models: models(spec),
      operations: operations(spec)
    }
    |> filter()
  end

  defp filter(%{models: models, operations: operations} = spec) do
    config = Context.get_config()
    operations = Enum.filter(operations, fn op -> config.op_gen?.(op.id) end)
    refs = collect_refs(extract_refs(operations))
    names = Enum.map(Map.keys(refs), &elem(&1, 0))
    models = Enum.filter(models, fn model -> model.name in names end)

    %{spec | models: models, operations: operations}
  end

  defp extract_refs(list) when is_list(list),
    do: Enum.reduce(list, %{}, &Map.merge(&2, extract_refs(&1)))

  defp extract_refs(%Object{props: props}) do
    Enum.reduce(props, %{}, fn {_, prop}, refs -> Map.merge(refs, extract_refs(prop)) end)
  end

  defp extract_refs(%Operation{} = op) do
    %{}
    |> Map.merge(extract_refs(op.body_params))
    |> Map.merge(extract_refs(op.query_params))
    |> Map.merge(extract_refs(op.path_params))
    |> Map.merge(extract_refs(op.request_body))
    |> Map.merge(extract_refs(op.responses))
  end

  defp extract_refs(%Ref{name: name, ref: ref}), do: %{{name, ref} => :new}
  defp extract_refs(%Prim{}), do: %{}
  defp extract_refs(%Array{of: of}), do: extract_refs(of)
  defp extract_refs(%Union{of: of}), do: Enum.reduce(of, %{}, &Map.merge(&2, extract_refs(&1)))
  defp extract_refs(%Any{}), do: %{}
  defp extract_refs(%Param{schema: schema}), do: extract_refs(schema)
  defp extract_refs(%Response{schema: schema}), do: extract_refs(schema)
  defp extract_refs(nil), do: %{}

  defp collect_refs(refs) do
    refs
    |> Enum.reduce({refs, false}, fn
      {{_name, _ref}, :seen}, {refs, more?} ->
        {refs, more?}

      {{name, ref}, :new}, {refs, _} ->
        {refs
         |> Map.merge(extract_refs(fetch(ref)), fn
           _k, :seen, _ -> :seen
           _k, :new, :new -> :new
         end)
         |> Map.put({name, ref}, :seen), true}
    end)
    |> case do
      {refs, true} -> collect_refs(refs)
      {refs, false} -> refs
    end
  end

  defp info(spec) do
    %{
      title: spec["info"]["title"],
      description: spec["info"]["description"],
      version: spec["info"]["version"]
    }
  end

  # 2.x
  defp models(%{"definitions" => defs}), do: models(defs)
  # 3.x
  defp models(%{"components" => %{"schemas" => defs}}), do: models(defs)
  defp models(%{"components" => _}), do: []

  defp models(defs) when is_map(defs) do
    for {name, schema} <- defs do
      %Model{
        name: name,
        title: schema["title"],
        description: schema["description"],
        schema: schema(schema)
      }
    end
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
      external_docs: external_docs(operation),
      method: method,
      path: path,
      path_params: params(params, "path"),
      query_params: params(params, "query"),
      body_params: params(params, "body"),
      request_body: request_body(operation),
      responses: responses(operation)
    }
  end

  defp external_docs(%{"external_docs" => %{"description" => description, "url" => url}}) do
    %{description: description, url: url}
  end

  defp external_docs(%{}), do: nil

  defp params(params, kind) do
    for %{"name" => name, "in" => ^kind} = param <- params do
      %Param{name: name, description: param["description"], schema: schema(param)}
    end
  end

  defp request_body(%{"requestBody" => body}), do: schema(body)
  defp request_body(_), do: nil

  defp responses(%{"responses" => responses}) do
    for {code, response} <- responses do
      schema =
        if response["content"] || response["schema"] do
          schema(response)
        else
          nil
        end

      %Response{
        code: code_or_default(code),
        schema: schema
      }
    end
  end

  defp responses(_), do: []

  defp code_or_default("default"), do: :default
  defp code_or_default(code), do: String.to_integer(code)
end
