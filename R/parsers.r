#' Parse raw data from solr_search, solr_facet, or solr_highlight.
#'
#' @param input Output from solr_facet
#' @param parsetype One of 'list' or 'df' (data.frame)
#' @param concat Character to conactenate strings by, e.g,. ',' (character). Used
#' in solr_parse.sr_search only.
#' @details This is the parser used internally in solr_facet, but if you output raw
#' data from solr_facet using raw=TRUE, then you can use this function to parse that
#' data (a sr_facet S3 object) after the fact to a list of data.frame's for easier
#' consumption. The data format type is detected from the attribute "wt" on the
#' sr_facet object.
#' @export
solr_parse <- function(input, parsetype = NULL, concat) {
  UseMethod("solr_parse")
}

#' @method solr_parse ping
#' @export
#' @rdname solr_parse
solr_parse.ping <- function(input, parsetype=NULL, concat=',') {
  wt <- attributes(input)$wt
  switch(wt,
         xml = xmlParse(input),
         json = jsonlite::fromJSON(input, simplifyDataFrame = FALSE, simplifyMatrix = FALSE))
}

#' @method solr_parse update
#' @export
#' @rdname solr_parse
solr_parse.update <- function(input, parsetype=NULL, concat=',') {
  wt <- attributes(input)$wt
  switch(wt,
         xml = xmlParse(input),
         json = jsonlite::fromJSON(input, simplifyDataFrame = FALSE, simplifyMatrix = FALSE),
         csv = jsonlite::fromJSON(input, simplifyDataFrame = FALSE, simplifyMatrix = FALSE)
  )
}

#' @method solr_parse sr_facet
#' @export
#' @rdname solr_parse
solr_parse.sr_facet <- function(input, parsetype=NULL, concat=',')
{
  stopifnot(is(input, "sr_facet"))
  wt <- attributes(input)$wt
  input_parsed <- switch(wt,
                         xml = xmlParse(input),
                         json = jsonlite::fromJSON(input, simplifyDataFrame = FALSE, simplifyMatrix = FALSE))

  # Facet queries
  if(wt=='json') {
    fqdat <- input_parsed$facet_counts$facet_queries
    if(length(fqdat)==0) {
      fqout <- NULL
    } else {
      fqout <- data.frame(term=names(fqdat), value=do.call(c, fqdat), stringsAsFactors=FALSE)
    }
    row.names(fqout) <- NULL
  } else {
    nodes <- xpathApply(input_parsed, '//lst[@name="facet_queries"]//int')
    if(length(nodes)==0){ fqout <- NULL } else { fqout <- nodes }
  }

  # facet fields
  if(wt=='json'){
    ffout <- lapply(input_parsed$facet_counts$facet_fields, function(x){
      data.frame(do.call(rbind, lapply(seq(1, length(x), by=2), function(y){
        x[c(y, y+1)]
      })), stringsAsFactors=FALSE)
    })
  } else {
    nodes <- xpathApply(input_parsed, '//lst[@name="facet_fields"]//lst')
    parselist <- function(x){
      tmp <- xmlToList(x)
      do.call(rbind.fill, lapply(tmp[!names(tmp) %in% ".attrs"], data.frame, stringsAsFactors=FALSE))
    }
    ffout <- lapply(nodes, parselist)
    names(ffout) <- sapply(nodes, xmlAttrs)
  }
  
  # facet pivot
  if(wt=='json'){
    pivot_input <- jsonlite::fromJSON(input, simplifyDataFrame = TRUE, simplifyMatrix = FALSE)$facet_count$facet_pivot[[1]]
    if(length(pivot_input)==0){
      fpout <- NULL
    } else {
      fpout <- list()
      pivots_left <- ('pivot' %in% names(pivot_input))
      if (pivots_left){
        infinite_loop_check <- 1
        while(pivots_left & infinite_loop_check < 100){
          stopifnot(is.data.frame(pivot_input))
          flattened_result <- pivot_flatten_tabular(pivot_input)
          fpout <- c(fpout, list(flattened_result$parent))
          pivot_input <- flattened_result$flattened_pivot
          pivots_left <- ('pivot' %in% names(pivot_input))
          infinite_loop_check <- infinite_loop_check + 1
        }
        fpout <- c(fpout, list(flattened_result$flattened_pivot))
      } else {
        fpout <- c(fpout, list(pivot_input))
      }
      fpout <- lapply(fpout, collapse_pivot_names)
      names(fpout) <- sapply(fpout, FUN=function(x){
        paste(head(names(x), -1), collapse=",")
      })
    }
  } else {
    message('facet.pivot results are not supported with XML response types, use wt="json"')
    fpout <- NULL
  }

  # Facet dates
  if(wt=='json') {
    if(length(input_parsed$facet_counts$facet_dates)==0) {
      datesout <- NULL
    } else {
      datesout <- lapply(input_parsed$facet_counts$facet_dates, function(x) {
        x <- x[!names(x) %in% c('gap','start','end')]
        x <- data.frame(date=names(x), value=do.call(c, x), stringsAsFactors=FALSE)
        row.names(x) <- NULL
        x
      })
    }
  } else {
    nodes <- xpathApply(input_parsed, '//lst[@name="facet_dates"]//int')
    if(length(nodes)==0){ datesout <- NULL } else { datesout <- nodes }
  }

  # Facet ranges
  if(wt=='json'){
    if(length(input_parsed$facet_counts$facet_ranges)==0){
      rangesout <- NULL
    } else {
      rangesout <- lapply(input_parsed$facet_counts$facet_ranges, function(x){
        x <- x[!names(x) %in% c('gap','start','end')]$counts
        data.frame(do.call(rbind, lapply(seq(1, length(x), by=2), function(y){
          x[c(y, y+1)]
        })), stringsAsFactors=FALSE)
      })
    }
  } else {
    nodes <- xpathApply(input_parsed, '//lst[@name="facet_ranges"]//int')
    if(length(nodes)==0){ rangesout <- NULL } else { rangesout <- nodes }
  }

  # output
  return( list(facet_queries = replacelen0(fqout),
               facet_fields = replacelen0(ffout),
               facet_pivot = replacelen0(fpout),
               facet_dates = replacelen0(datesout),
               facet_ranges = replacelen0(rangesout)) )
}

#' @method solr_parse sr_high
#' @export
#' @rdname solr_parse
solr_parse.sr_high <- function(input, parsetype='list', concat=',')
{
  stopifnot(is(input, "sr_high"))
  wt <- attributes(input)$wt
  input <- switch(wt,
                  xml = xmlParse(input),
                  json = jsonlite::fromJSON(input, simplifyDataFrame = FALSE, simplifyMatrix = FALSE))

  if(wt=='json'){
    if(parsetype=='df') {
      dat <- input$highlight
#       highout <- data.frame(term=names(dat), value=do.call(c, dat), stringsAsFactors=FALSE)
      highout <- data.frame(cbind(names=names(dat), do.call(rbind, dat)))
      row.names(highout) <- NULL
    } else {
      highout <- input$highlight
    }
  } else {
    highout <- xpathApply(input, '//lst[@name="highlighting"]//lst', xmlToList)
    tmptmp <- lapply(highout, function(x){
      meta <- x$.attrs[[1]]
      names(x) <- NULL
      as.list(c(meta = meta,
                sapply(x[-length(x)], function(y){
                  tmp <- y$str[[1]]
                  names(tmp) <- y$.attrs[[1]]
                  tmp
                })
      ))
    })
    if(parsetype=='df'){
      # highout <- do.call(rbind.fill, lapply(tmptmp, data.frame, stringsAsFactors=FALSE))
      highout <- rbind_all(lapply(tmptmp, as_data_frame))
#       dois <- xpathApply(input, '//lst[@name="highlighting"]//lst')
#       dois <- sapply(dois, function(x) xmlAttrs(x)['name'], USE.NAMES=FALSE)
#       nodes <- xpathApply(input, '//arr')
#       nn <- unique(sapply(nodes, function(x) xmlAttrs(x)['name'], USE.NAMES=FALSE))
#       data <- lapply(nn, function(x) xpathApply(input, sprintf('//arr[@name="%s"]', x), xmlValue))
#       highout <- data.frame(do.call(cbind, data))
#       names(highout) <- nn
    } else
    {
      highout <- tmptmp
    }
  }

  return( highout )
}

#' @method solr_parse sr_search
#' @export
#' @rdname solr_parse
solr_parse.sr_search <- function(input, parsetype='list', concat=',') {

  stopifnot(is(input, "sr_search"))
  wt <- attributes(input)$wt
  input <- switch(wt,
    xml = xmlParse(input),
    json = jsonlite::fromJSON(input, simplifyDataFrame = FALSE, simplifyMatrix = FALSE),
    csv = dplyr::tbl_df(read.table(text = input, sep = ",", stringsAsFactors = FALSE, header = TRUE, fill = TRUE, comment.char = ""))
  )

  if(wt=='json') {
    if(parsetype=='df') {
      dat <- input$response$docs
      dat2 <- lapply(dat, function(x) {
        lapply(x, function(y) {
          tmp <- if (length(y) > 1) {
            paste(y, collapse = concat)
          } else {
            y
          }
          if (is(y, "list")) unlist(tmp) else tmp
        })
      })
      # datout <- do.call(rbind.fill, lapply(dat2, data.frame, stringsAsFactors=FALSE))
      datout <- rbind_all(lapply(dat2, as_data_frame))
    } else {
      datout <- input
    }
  } else if (wt == "xml") {
    temp <- xpathApply(input, '//doc')
    tmptmp <- lapply(temp, function(x){
      tt <- xmlToList(x)
      uu <- lapply(tt, function(y){
        u <- y$text[[1]]
        names(u) <- y$.attrs[[1]]
        u
      })
      names(uu) <- NULL
      as.list(unlist(uu))
    })
    if (parsetype == 'df') {
      # datout <- do.call(rbind.fill, lapply(tmptmp, data.frame, stringsAsFactors=FALSE))
      datout <- rbind_all(lapply(tmptmp, as_data_frame))
    } else {
      datout <- tmptmp
    }
  } else {
    datout <- input
  }

  return( datout )
}

#' @method solr_parse sr_mlt
#' @export
#' @rdname solr_parse
solr_parse.sr_mlt <- function(input, parsetype='list', concat=',')
{
  stopifnot(is(input, "sr_mlt"))
  wt <- attributes(input)$wt
  input <- switch(wt,
                  xml = xmlParse(input),
                  json = jsonlite::fromJSON(input, simplifyDataFrame = FALSE, simplifyMatrix = FALSE))

  if (wt == 'json') {
    if (parsetype == 'df') {
      res <- input$response
      reslist <- lapply(res$docs, function(y) {
        lapply(y, function(z) {
          if (length(z) > 1) {
            paste(z, collapse = concat)
          } else {
            z
          }
        })
      })
#       resdat <- data.frame(do.call(rbind.fill, lapply(reslist, data.frame)),
#                            stringsAsFactors=FALSE)
      resdat <- rbind_all(lapply(reslist, as_data_frame))

      dat <- input$moreLikeThis
      dat2 <- lapply(dat, function(x){
        lapply(x$docs, function(y){
          lapply(y, function(z){
            if (length(z) > 1) {
              paste(z, collapse = concat)
            } else {
              z
            }
          })
        })
      })

      datmlt <- list()
      for (i in seq_along(dat)) {
        datmlt[[names(dat[i])]] <-
        do.call(rbind.fill, lapply(dat[[i]]$docs, function(y) {
          data.frame(lapply(y, function(z) {
            if (length(z) > 1) {
              paste(z, collapse = concat)
            } else {
              z
            }
          }), stringsAsFactors = FALSE)
        }))
      }

#       datmlt <- do.call(rbind.fill, lapply(dat2, data.frame, stringsAsFactors=FALSE))
#       row.names(datmlt) <- NULL
      datout <- list(docs = resdat, mlt = datmlt)
    } else
    {
      datout <- input$moreLikeThis
    }
  } else
  {
    res <- xpathApply(input, '//result[@name="response"]//doc')
    resdat <- do.call(rbind.fill, lapply(res, function(x){
      tmp <- xmlChildren(x)
      tmp2 <- sapply(tmp, xmlValue)
      names2 <- sapply(tmp, xmlGetAttr, name = "name")
      names(tmp2) <- names2
      data.frame(as.list(tmp2), stringsAsFactors = FALSE)
    }))

    temp <- xpathApply(input, '//doc')
    tmptmp <- lapply(temp, function(x){
      tt <- xmlToList(x)
      uu <- lapply(tt, function(y){
        u <- y$text[[1]]
        names(u) <- y$.attrs[[1]]
        u
      })
      names(uu) <- NULL
      as.list(unlist(uu))
    })

    if (parsetype == 'df') {
      # datout <- do.call(rbind.fill, lapply(tmptmp, data.frame, stringsAsFactors=FALSE))
      datout <- rbind_all(lapply(tmptmp, as_data_frame))
    } else
    {
      datout <- tmptmp
    }
  }

  return( datout )
}

#' @method solr_parse sr_stats
#' @export
#' @rdname solr_parse
solr_parse.sr_stats <- function(input, parsetype='list', concat=',')
{
  stopifnot(is(input, "sr_stats"))
  wt <- attributes(input)$wt
  input <- switch(wt,
                  xml = xmlParse(input),
                  json = jsonlite::fromJSON(input, simplifyDataFrame = FALSE, simplifyMatrix = FALSE))

  if (wt == 'json') {
    if (parsetype == 'df') {
      dat <- input$stats$stats_fields
      
      dat2 <- lapply(dat, function(x){
        data.frame(x[!names(x) %in% 'facets'])
      })
      dat_reg <- do.call(rbind, dat2)
        
      # parse the facets
      if (length(dat[[1]]$facets) == 0) {
        dat_facet <- NULL
      } else {
        dat_facet <- lapply(dat, function(x){
          facetted <- x[names(x) %in% 'facets'][[1]]
          if (length(facetted) == 1) {
            df <- do.call(rbind, lapply(facetted[[1]], function(z) data.frame(z[!names(z) %in% 'facets'])))
            df <- data.frame(df, row.names(df))
            names(df)[ncol(df)] <- names(facetted)
            row.names(df) <- NULL
          } else {
            df <- lapply(seq.int(length(facetted)), function(n){
              z <- facetted[[n]]
              dd <- do.call(rbind, lapply(z, function(zz) data.frame(zz[!names(zz) %in% 'facets'])))
              dd <- data.frame(dd, row.names(dd))
              row.names(dd) <- NULL
              names(dd)[ncol(dd)] <- names(facetted)[n]
              dd
            })
            names(df) <- names(facetted)
          }
          return(df)
        })
      }
      
      datout <- list(data = dat_reg, facet = dat_facet)
      
    } else {
      dat <- input$stats$stats_fields
      # w/o facets
      dat_reg <- lapply(dat, function(x){
        x[!names(x) %in% 'facets']
      })
      # just facets
      dat_facet <- lapply(dat, function(x){
        facetted <- x[names(x) %in% 'facets'][[1]]
        if (length(facetted) == 1) {
          lapply(facetted[[1]], function(z) z[!names(z) %in% 'facets'])
        } else {
          df <- lapply(facetted, function(z){
            lapply(z, function(zz) zz[!names(zz) %in% 'facets'])
          })
        }
      })

      datout <- list(data = dat_reg, facet = dat_facet)
    }
  } else {
    temp <- xpathApply(input, '//lst/lst[@name="stats_fields"]/lst')
    if (parsetype == 'df') {
      # w/o facets
      dat_reg <- do.call(rbind.fill, lapply(temp, function(h){
        tt <- xmlChildren(h)
        uu <- tt[!names(tt) %in% 'lst']
        vals <- sapply(uu, xmlValue)
        names2 <- sapply(uu, xmlGetAttr, name = "name")
        names(vals) <- names2
        data.frame(rbind(vals), stringsAsFactors = FALSE)
      }))
      # just facets
      dat_facet <- lapply(temp, function(e){
        tt <- xmlChildren(e)
        uu <- tt[names(tt) %in% 'lst']
        lapply(xmlChildren(uu$lst), function(f){
          do.call(rbind.fill, lapply(xmlChildren(f), function(g){
            ttt <- xmlChildren(g)
            uuu <- ttt[!names(ttt) %in% 'lst']
            vals <- sapply(uuu, xmlValue)
            names2 <- sapply(uuu, xmlGetAttr, name = "name")
            names(vals) <- names2
            data.frame(rbind(vals), stringsAsFactors = FALSE)
          }))
        })
      })
      datout <- list(data = dat_reg, facet = dat_facet)
    } else {
      dat_reg <- lapply(temp, function(h){
        title <- xmlAttrs(h)[[1]]
        tt <- xmlChildren(h)
        uu <- tt[!names(tt) %in% 'lst']
        vals <- sapply(uu, xmlValue)
        names2 <- sapply(uu, xmlGetAttr, name = "name")
        names(vals) <- names2
        ss <- list(x = as.list(vals))
        names(ss) <- title
        ss
      })
      # just facets
      dat_facet <- lapply(temp, function(e){
        title1 <- xmlAttrs(e)[[1]]
        tt <- xmlChildren(e)
        uu <- tt[names(tt) %in% 'lst']
        ssss <- lapply(xmlChildren(uu$lst), function(f){
          title2 <- xmlAttrs(f)[[1]]
          sss <- lapply(xmlChildren(f), function(g){
            title3 <- xmlAttrs(g)[[1]]
            ttt <- xmlChildren(g)
            uuu <- ttt[!names(ttt) %in% 'lst']
            vals <- sapply(uuu, xmlValue)
            names2 <- sapply(uuu, xmlGetAttr, name = "name")
            names(vals) <- names2
            ss <- list(x = as.list(vals))
            names(ss) <- eval(title3)
            ss
          })
          names(sss) <- rep(eval(title2), length(names(sss)))
          sss
        })
        names(ssss) <- rep(eval(title1), length(names(ssss)))
        ssss
      })
      datout <- list(data = dat_reg, facet = dat_facet)
    }
  }

  return( datout )
}

#' @method solr_parse sr_group
#' @export
#' @rdname solr_parse
solr_parse.sr_group <- function(input, parsetype='list', concat=',')
{
  stopifnot(is(input, "sr_group"))
  wt <- attributes(input)$wt
  input <- switch(wt,
                  xml = xmlParse(input),
                  json = jsonlite::fromJSON(input, simplifyDataFrame = FALSE, simplifyMatrix = FALSE))

  if(wt=='json'){
    if(parsetype=='df'){
      if(names(input) == 'response'){
        datout <- cbind(data.frame(numFound=input[[1]]$numFound,
                                   start=input[[1]]$start),
                        do.call(rbind.fill, lapply(input[[1]]$docs, data.frame, stringsAsFactors=FALSE)))
      } else {
        dat <- input$grouped
        if(length(dat)==1){
          if('groups' %in% names(dat[[1]])){
            datout <- dat[[1]]$groups
            datout <- do.call(rbind.fill, lapply(datout, function(x){
              df <- data.frame(groupValue=ifelse(is.null(x$groupValue),"none",x$groupValue),
                               numFound=x$doclist$numFound,
                               start=x$doclist$start)
              cbind(df, do.call(rbind.fill,
                lapply(x$doclist$docs, function(z){
                  data.frame(lapply(z, function(zz){
                    if(length(zz) > 1){
                      paste(zz, collapse=concat)
                    } else { zz }
                  }), stringsAsFactors=FALSE)
                })
              ))
            }))
          } else
          {
            datout <- cbind(data.frame(numFound=dat[[1]]$doclist$numFound,
                                       start=dat[[1]]$doclist$start),
                            do.call(rbind.fill, lapply(dat[[1]]$doclist$docs, data.frame, stringsAsFactors=FALSE)))
          }
        } else {
          if('groups' %in% names(dat[[1]])){
            datout <- lapply(dat, function(y){
              y <- y$groups
              do.call(rbind.fill, lapply(y, function(x){
                df <- data.frame(groupValue=ifelse(is.null(x$groupValue),"none",x$groupValue),
                                 numFound=x$doclist$numFound,
                                 start=x$doclist$start, stringsAsFactors=FALSE)
                cbind(df, do.call(rbind.fill, lapply(x$doclist$docs, data.frame, stringsAsFactors=FALSE)))
              }))
            })
          } else
          {
            datout <- do.call(rbind.fill, lapply(dat, function(x){
              df <- data.frame(numFound=x$doclist$numFound,
                               start=x$doclist$start, stringsAsFactors=FALSE)
              cbind(df, do.call(rbind.fill, lapply(x$doclist$docs, data.frame, stringsAsFactors=FALSE)))
            }))
          }
        }
      }
    } else {
      datout <- input$grouped
    }
  } else {
    temp <- xpathApply(input, '//lst/lst[@name="grouped"]/lst')
    if (parsetype == 'df') {
      datout <- "not done yet"
    } else {
      datout <- "not done yet"
    }
  }

  return( datout )
}

#' Flatten facet.pivot responses
#' 
#' Convert a nested hierarchy of facet.pivot elements 
#' to tabular data (rows and columns)
#' 
#' @param df_w_pivot a \code{data.frame} with another 
#' \code{data.frame} nested inside representing a 
#' pivot reponse
#' @return a \code{data.frame}
#' 
#' @keywords internal
pivot_flatten_tabular <- function(df_w_pivot){
  # drop last column assumed to be named "pivot"
  parent <- df_w_pivot[head(names(df_w_pivot),-1)]
  pivot <- df_w_pivot$pivot
  pp <- list()
  for (i in 1:nrow(parent)) {
    if ((!is.null(pivot[[i]])) && (nrow(pivot[[i]]) > 0)) {
      # from parent drop last column assumed to be named "count" to not create duplicate columns of information
      pp[[i]] <- data.frame(cbind(parent[i,], pivot[[i]], row.names = NULL))
    }
  }
  flattened_pivot <- do.call('rbind', pp)
  # return a tbl_df to flatten again if necessary
  return(list(parent = parent, flattened_pivot = flattened_pivot))
}

#' Collapse Pivot Field and Value Columns
#' 
#' Convert a table consisting of columns in sets of 3 
#' into 2 columns assuming that the first column of every set of 3
#' (field) is duplicated throughout all rows and should be removed. 
#' This type of structure is usually returned by facet.pivot responses.
#' 
#' @param data a \code{data.frame} with every 2 columns
#' representing a field and value and the final representing
#' a count
#' @return a \code{data.frame}
#' 
#' @keywords internal
collapse_pivot_names <- function(data){
  
  # shift field name to the column name to its right
  for (i in seq(1, ncol(data) - 1, by = 3)) {
    names(data)[i + 1] <- data[1, i]
  }
  
  # remove columns with duplicating information (anything named field)
  data <- data[-c(seq(1, ncol(data) - 1, by = 3))]
  
  # remove vestigial count columns
  if (ncol(data) > 2) {
    data <- data[-c(seq(0, ncol(data) - 1, by = 2))]
  }
  
  names(data)[length(data)] <- 'count'
  return(data)
}
