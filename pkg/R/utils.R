# Utilities and Helpers

# Given a JList<T>, returns an R list containing the same elements, the number
# of which is optionally upper bounded by `logicalUpperBound` (by default,
# return all elements).  Takes care of deserializations and type conversions.
convertJListToRList <- function(jList, flatten, logicalUpperBound = NULL, serialized = TRUE) {
  arrSize <- callJMethod(jList, "size")

  # Unserialized datasets (such as an RDD directly generated by textFile()):
  # each partition is not dense-packed into one Array[Byte], and `arrSize`
  # here corresponds to number of logical elements. Thus we can prune here.
  if (!serialized && !is.null(logicalUpperBound)) {
    arrSize <- min(arrSize, logicalUpperBound)
  }

  results <- if (arrSize > 0) {
    lapply(0:(arrSize - 1),
           function(index) {
             obj <- callJMethod(jList, "get", as.integer(index))

             # Assume it is either an R object or a Java obj ref.
             if (inherits(obj, "jobj")) {
               if (isInstanceOf(obj, "scala.Tuple2")) {
                 # JavaPairRDD[Array[Byte], Array[Byte]].

                 keyBytes = callJMethod(obj, "_1")
                 valBytes = callJMethod(obj, "_2")
                 res <- list(unserialize(keyBytes),
                             unserialize(valBytes))
               } else {
                 stop(paste("utils.R: convertJListToRList only supports",
                            "RDD[Array[Byte]] and",
                            "JavaPairRDD[Array[Byte], Array[Byte]] for now"))
               }
             } else {
               if (inherits(obj, "raw")) {
                 # RDD[Array[Byte]]. `obj` is a whole partition.
                 res <- unserialize(obj)
                 # For serialized datasets, `obj` (and `rRaw`) here corresponds to
                 # one whole partition dense-packed together. We deserialize the
                 # whole partition first, then cap the number of elements to be returned.

                 # TODO: is it possible to distinguish element boundary so that we can
                 # unserialize only what we need?
                 if (!is.null(logicalUpperBound)) {
                   res <- head(res, n = logicalUpperBound)
                 }
               } else {
                 # obj is of a primitive Java type, is simplified to R's
                 # corresponding type.
                 res <- list(obj)
               }
             }
             res
           })
  } else {
    list()
  }

  if (flatten) {
    as.list(unlist(results, recursive = FALSE))
  } else {
    as.list(results)
  }
}

# Returns TRUE if `name` refers to an RDD in the given environment `env`
isRDD <- function(name, env) {
  obj <- get(name, envir = env)
  inherits(obj, "RDD")
}

# Returns TRUE if `name` is a function in the SparkR package.
# TODO: Handle package-private functions as well ?
isSparkFunction <- function(name) {
  if (is.function(name)) {
    fun <- name
  } else {
    if (!(is.character(name) && length(name) == 1L || is.symbol(name))) {
      fun <- eval.parent(substitute(substitute(name)))
      if (!is.symbol(fun))
        stop(gettextf("'%s' is not a function, character or symbol",
                      deparse(fun)), domain = NA)
    } else {
      fun <- name
    }
    envir <- parent.frame(2)
    if (!exists(as.character(fun), mode = "function", envir = envir)) {
      return(FALSE)
    }
    fun <- get(as.character(fun), mode = "function", envir = envir)
  }
  packageName(environment(fun)) == "SparkR"
}

# Serialize the dependencies of the given function and return them as a raw
# vector. Filters out RDDs before serializing the dependencies
getDependencies <- function(name) {
  varsToSave <- c()
  closureEnv <- environment(name)

  currentEnv <- closureEnv
  while (TRUE) {
    # Don't serialize namespaces
    if (!isNamespace(currentEnv)) {
      varsToSave <- c(varsToSave, ls(currentEnv))
    }

    # Everything below globalenv are packages, search path stuff etc.
    if (identical(currentEnv, globalenv()))
       break
    currentEnv <- parent.env(currentEnv)
  }
  filteredVars <- Filter(function(x) { !isRDD(x, closureEnv) }, varsToSave)

  # TODO: A better way to exclude variables that have been broadcast
  # would be to actually list all the variables used in every function using
  # `all.vars` and then walking through functions etc.
  filteredVars <- Filter(
                    function(x) { !exists(x, .broadcastNames, inherits = FALSE) },
                    filteredVars)

  rc <- rawConnection(raw(), 'wb')
  save(list = filteredVars, file = rc, envir = closureEnv)
  binData <- rawConnectionValue(rc)
  close(rc)
  binData
}

#' Compute the hashCode of an object
#'
#' Java-style function to compute the hashCode for the given object. Returns
#' an integer value.
#'
#' @details
#' This only works for integer, numeric and character types right now.
#'
#' @param key the object to be hashed
#' @return the hash code as an integer
#' @export
#' @examples
#' hashCode(1L) # 1
#' hashCode(1.0) # 1072693248
#' hashCode("1") # 49
hashCode <- function(key) {
  if (class(key) == "integer") {
    as.integer(key[[1]])
  } else if (class(key) == "numeric") {
    # Convert the double to long and then calculate the hash code
    rawVec <- writeBin(key[[1]], con = raw())
    intBits <- packBits(rawToBits(rawVec), "integer")
    as.integer(bitwXor(intBits[2], intBits[1]))
  } else if (class(key) == "character") {
    .Call("stringHashCode", key)
  } else {
    warning(paste("Could not hash object, returning 0", sep = ""))
    as.integer(0)
  }
}

# Create a new RDD in serialized form.
# Return itself if already in serialized form.
reserialize <- function(rdd) {
  if (!inherits(rdd, "RDD")) {
    stop("Argument 'rdd' is not an RDD type.")
  }
  if (rdd@env$serialized) {
    return(rdd)
  } else {
    ser.rdd <- lapply(rdd, function(x) { x })
    return(ser.rdd)
  }
}

# Fast append to list by using an accumulator.
# http://stackoverflow.com/questions/17046336/here-we-go-again-append-an-element-to-a-list-in-r
#
# The accumulator should has three fields size, counter and data.
# This function amortizes the allocation cost by doubling
# the size of the list every time it fills up.
addItemToAccumulator <- function(acc, item) {
  if(acc$counter == acc$size) {
    acc$size <- acc$size * 2
    length(acc$data) <- acc$size
  }
  acc$counter <- acc$counter + 1
  acc$data[[acc$counter]] <- item
}

initAccumulator <- function() {
  acc <- new.env()
  acc$counter <- 0
  acc$data <- list(NULL)
  acc$size <- 1
  acc
}

# Utility function to sort a list of key value pairs
# Used in unit tests
sortKeyValueList <- function(kv_list, decreasing = FALSE) {
  keys <- sapply(kv_list, function(x) x[[1]])
  kv_list[order(keys, decreasing = decreasing)]
}

# Utility function to generate compact R lists from grouped rdd
# Used in Join-family functions
# param:
#   tagged_list R list generated via groupByKey with tags(1L, 2L, ...)
#   cnull Boolean list where each element determines whether the corresponding list should
#         be converted to list(NULL)
genCompactLists <- function(tagged_list, cnull) {
  len <- length(tagged_list)
  lists <- list(vector("list", len), vector("list", len))
  index <- list(1, 1)

  for (x in tagged_list) {
    tag <- x[[1]]
    idx <- index[[tag]]
    lists[[tag]][[idx]] <- x[[2]]
    index[[tag]] <- idx + 1
  }

  len <- lapply(index, function(x) x - 1)
  for (i in (1:2)) {
    if (cnull[[i]] && len[[i]] == 0) {
      lists[[i]] <- list(NULL)
    } else {
      length(lists[[i]]) <- len[[i]]
    }
  }

  lists
}

# Utility function to merge compact R lists
# Used in Join-family functions
# param:
#   left/right Two compact lists ready for Cartesian product
mergeCompactLists <- function(left, right) {
  result <- list()
  length(result) <- length(left) * length(right)
  index <- 1
  for (i in left) {
    for (j in right) {
      result[[index]] <- list(i, j)
      index <- index + 1
    }
  }
  result
}

# Utility function to wrapper above two operations
# Used in Join-family functions
# param (same as genCompactLists):
#   tagged_list R list generated via groupByKey with tags(1L, 2L, ...)
#   cnull Boolean list where each element determines whether the corresponding list should
#         be converted to list(NULL)
joinTaggedList <- function(tagged_list, cnull) {
  lists <- genCompactLists(tagged_list, cnull)
  mergeCompactLists(lists[[1]], lists[[2]])
}

# Utility function to reduce a key-value list with predicate
# Used in *ByKey functions
# param
#   pair key-value pair
#   keys/vals env of key/value with hashes
#   updateOrCreatePred predicate function
#   updateFn update or merge function for existing pair, similar with `mergeVal` @combineByKey
#   createFn create function for new pair, similar with `createCombiner` @combinebykey
updateOrCreatePair <- function(pair, keys, vals, updateOrCreatePred, updateFn, createFn) {
  # assume hashVal bind to `$hash`, key/val with index 1/2
  hashVal <- pair$hash
  key <- pair[[1]]
  val <- pair[[2]]
  if (updateOrCreatePred(pair)) {
    assign(hashVal, do.call(updateFn, list(get(hashVal, envir = vals), val)), envir = vals)
  } else {
    assign(hashVal, do.call(createFn, list(val)), envir = vals)
    assign(hashVal, key, envir=keys)
  }
}

# Utility function to convert key&values envs into key-val list
convertEnvsToList <- function(keys, vals) {
  lapply(ls(keys),
         function(name) {
           list(keys[[name]], vals[[name]])
         })
}
