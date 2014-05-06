#########################################################################
#
#   ExGraph type definition and related functions
#
#########################################################################
  

#####  ExGraph type definition ######
type ExGraph
  nodes::Vector{ExNode}  # nodes in this graph
  ext_inodes::BiDict{ExNode, Any}
  set_inodes::BiDict{ExNode, Any}
  ext_onodes::BiDict{ExNode, Any}
  set_onodes::BiDict{ExNode, Any}
end

ExGraph()                   = ExGraph( ExNode[] )
ExGraph(vn::Vector{ExNode}) = ExGraph( vn, BiDict{ExNode, Any}(), 
                                           BiDict{ExNode, Any}(), 
                                           BiDict{ExNode, Any}(), 
                                           BiDict{ExNode, Any}() )


#####  ExGraph functions  #####

# copies a graph and its nodes, leaves external nodes references intact
function copy(g::ExGraph)
  g2 = ExGraph()
  nmap = Dict()
  evalsort!(g)
  for n in g.nodes
    n2 = addnode!(g2, copy(n))
    n2.parents = [ nmap[n] for n in n2.parents ]
    nmap[n] = n2
  end

  # copy node mapping and translate inner nodes to newly created ones
  g2.ext_onodes = BiDict{ExNode, Any}(g.ext_onodes.kv)
  g2.set_onodes = BiDict{ExNode, Any}(g.set_onodes.kv)
  for (k,v) in g.ext_inodes.kv
    g2.ext_inodes[ nmap[k] ] = v
  end
  for (k,v) in g.set_inodes.kv
    g2.set_inodes[ nmap[k] ] = v
  end

  g2
end

# add a single node
addnode!(g::ExGraph, nn::ExNode) = ( push!(g.nodes, nn) ; return g.nodes[end] )

######## transforms n-ary +, *, max, min, sum, etc...  into binary ops  ###### 
function splitnary!(g::ExGraph)
  for n in g.nodes
      if isa(n, NCall) &&
          in(n.main, [:+, :*, :sum, :min, :max]) && 
          (length(n.parents) > 2 )

          nn = addnode!(g, NCall( n.main, n.parents[2:end] ) )
          n.parents = [n.parents[1], nn]  
      
      elseif isa(n, NFor)
        splitnary!(n.main[2])

      end
  end
end

####### fuses nodes nr and nk, keeps nk ########
# removes node nr and keeps node nk 
#  updates all references to nr
function fusenodes(g::ExGraph, nk::ExNode, nr::ExNode)
  # replace references to nr by nk in parents of other nodes
  for n in filter(n -> n != nr && n != nk, g.nodes)
    for i in 1:length(n.parents)
      n.parents[i] == nr && (n.parents[i] = nk)
    end
  end

  haskey(g.ext_inodes, nr) && error("[fusenodes] attempt to fuse ext_inode $nr")
  if haskey(g.set_inodes, nr)
    haskey(g.set_inodes, nk) && error("[fusenodes] $nk (nk) is a set_inode, can't remove $nr")
    g.set_inodes[nk] = g.set_inodes[nr]  # nk replaces nr as set_inode
  end

  # now check for loops that may refer to nr
  for n in filter(n -> isa(n, NFor) && n != nr && n != nk, g.nodes)
    g2 = n.main[2]

    haskey(g2.set_onodes, nr) && error("[fusenodes (for)] attempt to fuse out_onode $nr")
    if haskey(g2.ext_onodes, nr)
      haskey(g2.ext_onodes, nk) && error("[fusenodes (for)] $nk (nk) already in map, can't remove $nr")
      g2.ext_onodes[nk] = g2.ext_onodes[nr] # nk replaces nr as ext_onode
    end  
  end

  # remove node nr in g
  filter!(n -> n != nr, g.nodes)
end

####### trims the graph to necessary nodes for exitnodes to evaluate  ###########
prune!(g::ExGraph) = prune!(g, collect(keys(g.set_inodes.kv)))

function prune!(g::ExGraph, exitnodes)
  ns2 = copy(exitnodes)
  evalsort!(g)
  for n in reverse(g.nodes)
    n in ns2 || continue

    if isa(n, NFor)
      g2 = n.main[2]

      # list of g2 nodes whose outer node is in ns2
      exitnodes2 = ExNode[]
      for (k, sym) in g2.set_onodes.kv
        k in ns2 || continue
        push!(exitnodes2, g2.set_inodes.vk[sym])
      end

      prune!(g2, exitnodes2)

      # update parents
      n.parents = intersect(n.parents, collect(keys(g2.ext_onodes)) )
    end

    ns2 = union(ns2, n.parents)
  end

  # remove unused external inodes in map and corresponding onodes (if they exist)
  for (k,v) in g.ext_inodes.kv
    k in ns2 && continue
    delete!(g.ext_inodes, k)
    haskey(g.ext_onodes.vk, v) && delete!(g.ext_onodes, g.ext_onodes.vk[v])
  end
  # reduce set inodes to what was specified in initial exitnodes parameter
  for (k,v) in g.set_inodes.kv
    k in exitnodes && continue
    delete!(g.set_inodes, k)
    haskey(g.set_onodes.vk, v) && delete!(g.set_onodes, g.set_onodes.vk[v])
  end

  g.nodes = intersect(g.nodes, ns2)
end


####### sort graph to an evaluable order ###########
function evalsort!(g::ExGraph)
  g2 = ExNode[]
  while length(g2) < length(g.nodes)
    canary = length(g2)
    nl = setdiff(g.nodes, g2)
      for n in nl
          any(x -> x in nl, n.parents) && continue
            push!(g2,n)
      end
      (canary == length(g2)) && error("[evalsort!] probable cycle in graph")
  end
  g.nodes = g2

  # separate pass on subgraphs
  map( n -> evalsort!(n.main[2]), filter(n->isa(n, NFor), g.nodes))
end

####### calculate the value of each node  ###########
function calc!(g::ExGraph; params=Dict(), emod = Main)

  function myeval(thing)
    local ret   
    if haskey(params, thing)
      return params[thing]
    else
      try
        ret = emod.eval(thing)
      catch e
        println("[calc!] can't evaluate $thing")
        rethrow(e)
      end
      return ret
    end
  end

  function evaluate(n::Union(NAlloc, NCall))
    local ret
    try
      ret = invoke(emod.eval(n.main), 
        tuple([ typeof(x.val) for x in n.parents]...),
        [ x.val for x in n.parents]...)
    catch
      error("[calc!] can't evaluate $(n.main)")
    end
    return ret
  end 

  function evaluate(n::NExt)
    haskey(g.ext_inodes, n) || return myeval(n.main)

    sym = g.ext_inodes[n]  # should be equal to n.main but just to be sure.. 
    haskey(g.ext_onodes.vk, sym) || return myeval(n.main)
    return g.ext_onodes.vk[sym].val  # return node val in parent graph

    # if haskey(g.map.vk, (n.main, :out_onode))
    #   pn = g.map.vk[(n.main, :out_onode)]
    #   return pn.val      # get node val in parent graph
    # else
    #   return myeval(n.main)  # get value of symbol
    # end
  end

  evaluate(n::NConst) = n.main
  evaluate(n::NRef)   = myeval( Expr(:ref, n.parents[1].val, 
                                     map(a->myeval(a), n.main)... ) )
  evaluate(n::NDot)   = myeval( Expr(  :., n.parents[1].val, n.main) )
  evaluate(n::NSRef)  = n.parents[1].val
  evaluate(n::NSDot)  = n.parents[1].val
  evaluate(n::NIn)    = n.parents[1].val[n]

  function evaluate(n::NFor)
    g2 = n.main[2]
    is = n.main[1].args[1]           # symbol of loop index
    iter = myeval(n.main[1].args[2])
    is0 = next(iter, start(iter))[2] # first value of index
    params2 = merge(params, { is => is0 }) 
    # println("params2 : $(params2)")
    calc!(n.main[2], params=params2)
    
    valdict = Dict()
    for (k, sym) in g2.set_onodes
      valdict[k] = g2.set_inodes.vk[sym].val
    end

    valdict
  end

  evalsort!(g)
  for n in g.nodes
    n.val = evaluate(n)
  end
end

###### inserts graph src into dest  ######
function addgraph!(src::ExGraph, dest::ExGraph, smap::Dict)
  evalsort!(src)
  nmap = Dict()
  for n in src.nodes  #  n = src[1]  
    if !isa(n, NExt)
      nn = copy(n) # node of same type
      nn.parents = [ nmap[n2] for n2 in n.parents ]
      push!(dest.nodes, nn)
      nmap[n] = nn

    else
      if haskey(smap, n.main)
        nmap[n] = smap[n.main]
      else
        nn = copy(n)
        push!(dest.nodes, nn)
        # nn = addnode!(dest, n.nodetype, n.main, [])
        nmap[n] = nn
        warn("unmapped symbol in source graph $(n.main)")
      end

    end
  end

  nmap
end

###### plots graph using GraphViz
function plot(g::ExGraph)

  gshow(n::NConst) = 
    "$(nn[n]) [label=\"$(n.main)\", shape=\"square\", style=filled, fillcolor=\"lightgreen\"];"
  gshow(n::NExt)   = 
    "$(nn[n]) [label=\"$(n.main)\", shape=\"circle\", style=filled, fillcolor=\"orange\"];"
  gshow(n::NCall)  = 
    "$(nn[n]) [label=\"$(n.main)\", shape=\"box\", style=filled, fillcolor=\"lightblue\"];"
  gshow(n::NComp)  = 
    "$(nn[n]) [label=\"$(n.main)\", shape=\"box\", style=filled, fillcolor=\"lightblue\"];"
  gshow(n::NRef)   = 
    "$(nn[n]) [label=\"$(n.main)\", shape=\"rarrow\", style=filled, fillcolor=\"lightblue\"];"
  gshow(n::NDot)   = 
    "$(nn[n]) [label=\"$(n.main)\", shape=\"rarrow\", style=filled, fillcolor=\"lightblue\"];"
  gshow(n::NSRef)  = 
    "$(nn[n]) [label=\"$(n.main)\", shape=\"larrow\", style=filled, fillcolor=\"lightblue\"];"
  gshow(n::NSDot)  = 
    "$(nn[n]) [label=\"$(n.main)\", shape=\"larrow\", style=filled, fillcolor=\"lightblue\"];"
  gshow(n::NAlloc) = 
    "$(nn[n]) [label=\"$(n.main)\", shape=\"parallelogram\", style=filled, fillcolor=\"lightblue\"];"
  gshow(n::NIn)    = 
    "$(nn[n]) [label=\"in\", shape=\"box3d\", style=filled, fillcolor=\"pink\"];"

  nn = Dict() # node names for GraphViz
  i = 1
  out = ""
  for n in g.nodes
    if isa(n, NFor)  # FIXME : will fail for nested for loops
      nn[n] = "cluster_$i"
      i += 1
      out = out * """
          subgraph $(nn[n]) { label=\"for $(n.main[1])\" ; 
          color=pink;
        """

      # for n2 in filter(n -> !isa(n, NExt), n.main[2].nodes)
      for n2 in n.main[2].nodes
          nn[n2] = "n$i"
        i += 1
        out = out * gshow(n2)
      end

      out = out * "};"
    else
      nn[n] = "n$i"
      i += 1
      out = out * gshow(n)
    end 
  end

  for n in g.nodes 
    if isa(n, NFor)  # FIXME : will fail for nested for loops
      g2 = n.main[2]
      for n2 in g2.nodes
        if isa(n2, NExt)
          p = g2.inmap[n2]
              out = out * "$(nn[p]) -> $(nn[n2]) [style=dashed];"
        else  
            for p in n2.parents
              out = out * "$(nn[p]) -> $(nn[n2]);"
            end
        end

        if haskey(g2.outmap, n2)
          p = g2.outmap[n2]
              out = out * "$(nn[n2]) -> $(nn[p]) [style=dashed];"
            end

        if haskey(g2.link, n2)
          p = g2.link[n2]
              out = out * "$(nn[n2]) -> $(nn[p]) [style=dotted, color=\"blue\"];"
            end

      end
    else
        for p in filter(n -> !isa(n, NFor), n.parents)
            out = out * "$(nn[p]) -> $(nn[n]);"
        end
    end 
  end

  for (el, en) in g.setmap
      out = out * "n$el [label=\"$el\", shape=\"note\", stype=filled, fillcolor=\"lightgrey\"];"
      out = out * "$(nn[en]) -> n$el [ style=dotted];"
  end

  "digraph gp {layout=dot; $out }"
end