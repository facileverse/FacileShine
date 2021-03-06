#' A categoricalSampleCovariate selector
#'
#' This is the second version of this module, which was updated to allow for a
#' `universe` argument, which specifies a subset of samples from `rfds` to get
#' covariate data from. The original implementation always retrieved covariates
#' from `active_samples(rfds)`. If `universe = NULL`, original behavior is
#' kept.
#'
#' @section Excluding covariates:
#'
#' TODO: Let's talk about how to exclude covariates and their levels, and point
#' users to [update_exclude()]
#'
#' @rdname categoricalSampleCovariateSelect
#' @export
#' @importFrom shiny
#'   isolate
#'   observe
#'   reactive
#'   reactiveValues
#'   req
#'   updateSelectInput
#' @param default_covariate the name of a covariate to use as the default
#'   one that is selected here, if available
#' @param a reactive character vector, which specifies the covariates to ignore
#'   or a tibble with "variable" (and optional "value") columns. If a character
#'   vector, or tibble with just has a "variable" column are provide, then
#'   the variable names enumerated there will not be included in this dropdown.
#'   A tibble with "variable" and "value" columns can be used so that only
#'   specific levels of a covariate are ignored.
categoricalSampleCovariateSelect <- function(input, output, session, rfds,
                                             universe = NULL, include1 = TRUE,
                                             default_covariate = NULL,
                                             ...,
                                             .with_none = TRUE,
                                             .exclude = NULL,
                                             .reactive = TRUE,
                                             ignoreNULL = TRUE,
                                             debug = FALSE) {
  assert_class(rfds, "ReactiveFacileDataStore")
  if (!is.null(universe)) assert_class(universe, "reactive")

  isolate. <- if (.reactive) base::identity else shiny::isolate

  state <- reactiveValues(
    covariate = "__initializing__",
    levels = "__initializing__",
    summary = .empty_covariate_summary(rfds),
    active_covariates = "__initializing__",
    universe = "__initializing__",
    exclude = tibble(variable = character(), value = character()))

  if (!is.null(.exclude)) {
    assert_class(.exclude, "reactive")
  }

  observe({
    req(initialized(rfds))
    update_exclude(state, .exclude, type = "covariate_select")
  }, priority = 10)
  exclude. <- reactive(state$exclude)

  observe({
    req(initialized(rfds))
    ftrace("Updating covaraite sample universe using rfds: ", isolate(name(rfds)))

    if (is.null(universe)) {
      univ <- isolate.(active_samples(rfds))
    } else {
      # This has been previously given a restricted universe taht is
      # separate from active_samples(rfds). Let's make sure those samples
      # still map to the current rfds.
      univ <- isolate.(universe())
      if (!test_sample_subset(univ, rfds)) {
        fwarn("The restricted universe does not match underlying fds ",
              "... remoeving restriction")
        univ <- isolate(active_samples(rfds))
      }
    }
    state$universe <- univ
  }, priority = 10)

  universe. <- reactive({
    req(test_sample_subset(state$universe))
    state$universe
  })

  observe({
    depend(rfds, "covariates")
    req(initialized(rfds))
    univ <- universe.()
    req(is.data.frame(univ))

    ftrace("Updating {bold}{red}state$active_covariates{reset}")
    # acovs <- try(fetch_sample_covariates(rfds, univ), silent = TRUE)
    # if (is(acovs, "try-error")) browser()

    acovs <- fetch_sample_covariates(rfds, univ)
    acovs <- filter(acovs, class %in% c("categorical", "logical"))
    ignore <- exclude.()
    if (nrow(ignore)) {
      anti.by <- intersect(c("variable", "value"), names(ignore))
      acovs <- anti_join(acovs, ignore, by = anti.by)
    }

    state$active_covariates <- summary(acovs)
  }, priority = 10)

  active.covariates <- reactive({
    req(initialized(rfds))
    covs <- state$active_covariates
    req(is.data.frame(covs))
    covs
  })

  categorical.covariates <- reactive({
    out <- req(active.covariates())
    if (!include1) {
      out <- filter(out, nlevels > 1L)
    }
    pull(out, variable)
  })

  # Updating the covariate select dropdown is a little tricky because we want
  # to support the situation where the current active.covariates change in
  # response to the current set of active_samples changing.
  #
  # Because this event listens to the underlying active.covariates() and can
  # update the internal state of the selected covariate, we want crank up the
  # priority to 10, so that if a covariate "goes missing" in a cohort swap,
  # the selected covariate gets reset to unselected
  observeEvent(categorical.covariates(), {
    choices <- categorical.covariates()

    ftrace("Updating available covariates to select from")

    choices <- sort(choices)
    if (.with_none) {
      choices <- c("---", choices)
    }

    selected <- input$covariate
    if (unselected(selected)) selected <- default_covariate

    overlap <- intersect(selected, choices)
    if (length(overlap)) {
      if (!setequal(state$covariate, overlap)) state$covariate <- overlap
      selected <- overlap
    } else {
      # selected <- NULL
      # state$covariate <- ""
      selected <- if (.with_none) "---" else NULL
      state$covariate <- ""
    }

    updateSelectInput(session, "covariate", choices = choices,
                      selected = selected)
  }, priority = 10)

  observeEvent(input$covariate, {
    cov <- input$covariate
    # req(!is.null(cov)) # NULL
    current <- state$covariate
    if (unselected(cov)) cov <- ""
    if (!setequal(cov, current)) {
      ftrace("{bold}Updating covariate state: {current} -> {cov}{reset}",
             current = current, cov = cov)
      state$covariate <- cov
    }
  }, ignoreNULL = ignoreNULL)

  covariate <- reactive(state$covariate)

  covariate.summary <- reactive({
    covariate. <- covariate()
    allcovs. <- active.covariates()
    notselected <- unselected(covariate.) ||
      !covariate. %in% allcovs.[["variable"]]

    # if (grepl("human", name(rfds), ignore.case = TRUE)) browser()

    ftrace("Calculating covariate({red}", covariate., "{reset}) summary")

    if (notselected) {
      out <- .empty_covariate_summary(rfds)
    } else {
      # Need to isolate the [sample] universe.() because that is updated at a
      # higher priority, and sometimes when samples changed via cohort
      # selection, it was triggering this code block to fire before the selected
      # covariate could be reset to one that exists in this cohort (ie. if the
      # cohort shift removes the currently selected covariate from the cohort).
      univ <- isolate(universe.())
      scovs <- try(fetch_sample_covariates(rfds, univ, covariate.), silent = TRUE)
      req(!is(scovs, "try-error"))
      out <- summary(scovs, expanded = TRUE)
    }
    out
  })

  observeEvent(req(covariate.summary()), {
    csummary <- req(covariate.summary())
    lvls <- csummary[["level"]]
    if (!setequal(state$levels, lvls)) {
      ftrace("Resetting available levels for {red}", isolate(covariate()), "{reset}")
      state$levels <- lvls
    }
  }, priority = 10)

  cov.levels <- reactive({
    req(state$levels != "__initializing__")
    state$levels
  })

  vals <- list(
    covariate = covariate,
    summary = covariate.summary,
    levels = cov.levels,
    catcovs = categorical.covariates,
    .state = state,
    .ns = session$ns)
  class(vals) <- c("CategoricalCovariateSelect",
                   "CovariateSelect",
                   "FacileDataAPI",
                   "Labeled")
  return(vals)
}

#' @noRd
#' @export
#' @rdname categoricalSampleCovariateSelect
#' @importFrom shiny NS selectInput
categoricalSampleCovariateSelectUI <- function(id, label = "Covariate",
                                               choices = NULL, selected = NULL,
                                               multiple = FALSE,
                                               selectize = TRUE, width = NULL,
                                               size = NULL, ...) {
  ns <- NS(id)

  tagList(
    selectInput(ns("covariate"), label = label, choices = choices,
                selected = selected, multiple = multiple, selectize = selectize,
                width = width, size = size))
}

update_selected <- function(x, covariate, ...) {
  # TODO: enable callback/update of the selected categorical covariate
}

#' @noRd
#' @export
name.CategoricalCovariateSelect <- function(x, ...) {
  out <- x[["covariate"]]()
  if (unselected(out)) NULL else out
}

#' @noRd
#' @export
label.CategoricalCovariateSelect <- function(x, ...) {
  warning("TODO: Need to provide labels for categorical covariates")
  x[["covariate"]]()
}


# Covariate Levels Selector ====================================================

#' Use this with categoricalSampleCovariateSelect to enumerate its levels.
#'
#' @export
#' @rdname categoricalSampleCovariateLevels
#' @param covaraite the `categoricalSampleCovariateSelect` module.
#' @param missing_sentinel This is a reactive (string). When it's NULL, no
#'   missing sentinel is added. The parent covariate selector can pass in a
#'   value here to show to indicate a level that's not included in the
#'   covariate's level.
#' @importFrom shiny updateSelectizeInput
categoricalSampleCovariateLevels <- function(input, output, session, rfds,
                                             covariate, missing_sentinel = NULL,
                                             ..., .exclude = NULL,
                                             .reactive = TRUE, debug = FALSE) {
  isolate. <- if (.reactive) base::identity else shiny::isolate
  if (!is.null(missing_sentinel)) {
    # This should be a reactive string
    if (!is(missing_sentinel, "reactive")) {
      fwarn("missing_sentinal is not a reactive")
    }
  }

  assert_class(rfds, "ReactiveFacileDataStore")
  state <- reactiveValues(
    values = "__initializing__",
    levels = character(),
    exclude = character())

  observe({
    req(initialized(rfds))
    update_exclude(state, isolate(.exclude), type = "covariate_levels")
  })
  exclude. <- reactive(state$exclude)

  observe({
    req(initialized(rfds))
    levels. <- req(covariate$levels())
    if (!is.null(missing_sentinel)) {
      levels. <- unique(c(levels., missing_sentinel()))
    }

    ignore <- exclude.()
    newlevels <- setdiff(levels., ignore)
    if (!setequal(state$levels, newlevels)) {
      ftrace("Updating levels from (", state$levels, "), to (",
             newlevels, ")")
      state$levels <- newlevels
    }
  }, priority = 10)

  levels <- reactive(state$levels)

  observeEvent(levels(), {
    req(initialized(rfds))
    levels. <- levels()
    selected. <- input$values
    if (unselected(selected.)) selected. <- ""

    overlap. <- intersect(selected., levels.)
    if (unselected(overlap.)) overlap. <- ""
    if (!isTRUE(setequal(overlap., state$values))) {
      ftrace("change in availavble levels (",
             paste(levels., collapse = ","),
             ") updates selected level to: `", overlap., "`")
      state$values <- overlap.
    }
    updateSelectizeInput(session, "values", choices = levels.,
                         selected = overlap., server = TRUE)
  }, priority = 10)

  observeEvent(input$values, {
    selected. <- input$values
    # This is required because ignoreNULL is set to `FALSE`. We set it to
    # false so that when all selected levels are removed from
    # covariateSelectLevels, the values are released "back to the pool".
    # When ignoreNULL is false, however, there are intermediate in the
    # reactivity cycle when input$values is NULL even though its value
    # hasn't changed.
    #
    # The latter situation hit me when I was trying to make "mutually
    # exclusive" categoricalSampleCovariateLevels that are populated
    # from the same categoricalCovariateSelect by using the .exclude
    # mojo

    # THIS IS SO CLOSE: I need to put the req(!is.null()) here for the
    # mutually-excluve categoricalCovariateSelectLevel modules to work.
    # TODO: Finish categoricalSampleCovariateLevelsMutex
    # req(!is.null(selected.))
    if (unselected(selected.)) {
      selected. <- ""
    }
    if (!isTRUE(setequal(selected., state$values))) {
      ftrace("Change of selected input$values changes internal state from ",
             "`", isolate(state$values), "` ",
             "to {bold}{magenta}`", selected., "`{reset}")
      # logical covariates are stored as 0/1 when retrieved out of SQLite
      # database, let's convert T/F to 0/1 here, too
      csummary <- covariate$summary()
      if (nrow(csummary) > 0L && csummary[["class"]] == "logical") {
        selected. <- ifelse(selected. == "TRUE", "1", selected.)
        selected. <- ifelse(selected. == "FALSE", "0", selected.)
      }
      state$values <- selected.
    }
  }, ignoreNULL = FALSE)

  values <- reactive(state$values)

  if (debug) {
    output$selected <- renderText(values())
  }

  vals <- list(
    values = values,
    levels = levels,
    .state = state,
    .ns = session$ns)
  class(vals) <- "CategoricalCovariateSelectLevels"
  return(vals)
}

#' @noRd
#' @export
#' @rdname categoricalSampleCovariateLevels
#' @importFrom shiny NS selectizeInput tagList textOutput
categoricalSampleCovariateLevelsUI <- function(id, ..., choices = NULL,
                                               options = NULL, width = NULL,
                                               debug = FALSE) {
  ns <- NS(id)

  out <- tagList(
    selectizeInput(ns("values"), ..., choices = choices,
                   options = options, width = width))
  if (debug) {
    out <- tagList(
      out,
      tags$p("Selected levels:", textOutput(ns("selected"))))
  }

  out
}

# Mutually Exclusive select labels from one covariate ==========================
# Implementation inspired by Caleb Lareau
# https://github.com/caleblareau/mutuallyExclusiveShiny


#' Creates arbitrary n-level selects from a single categorical covariate whose
#' options are mutually exclusive of each other.
#'
#' @export
#' @importFrom shiny column insertUI req selectizeInput uiOutput updateSelectizeInput
#' @param covariate a [categoricalSampleCovariateSelect()] module.
categoricalSampleCovariateLevelsMutex <- function(
    input, output, session, rfds,
    covariate, label1 = "Value 1", label2 = "Value 2",
    multiple1 = TRUE, multiple2 = TRUE, ...,
    .exclude = NULL,
    .reactive = TRUE,
    debug = FALSE) {
  ns <- session$ns

  isolate. <- if (.reactive) base::identity else shiny::isolate
  assert_character(inpt_names, min.len = 2L)

  assert_class(rfds, "ReactiveFacileDataStore")
  state <- reactiveValues(
    values1 = "",
    values2 = "",
    selected = "",
    levels = character(),
    exclude = character())

  exclude. <- reactive({
    if (is.null(.exclude)) NULL else .exclude()
  })

  observe({
    req(initialized(rfds))
    levels. <- req(covariate$levels())
    ignore <- exclude.()
    newlevels <- setdiff(levels., ignore)
    if (!setequal(state$levels, newlevels)) {
      ftrace("Updating levels from (", state$levels, "), to (",
             newlevels, ")")
      state$levels <- newlevels
    }
  }, priority = 10)

  levels <- reactive(state$levels)

  # AAAAAAARGHHHHHHHHHHHHHHHHHHHHH ---------------------------------------------
  observe({
    state$values1 <- input$values1
    state$values2 <- input$values2
  })

  observeEvent(levels(), {
    req(initialized(rfds))
    levels. <- levels()
    selected. <- input$values
    if (unselected(selected.)) selected. <- ""

    overlap. <- intersect(selected., levels.)
    if (unselected(overlap.)) overlap. <- ""
    if (!isTRUE(setequal(overlap., state$values))) {
      ftrace("change in availavble levels (",
             paste(levels., collapse = ","),
             ") updates selected level to: `", overlap., "`")
      state$values <- overlap.
    }
    updateSelectizeInput(session, "values", choices = levels.,
                         selected = overlap., server = TRUE)
  }, priority = 10)

  observeEvent(input$values, {
    selected. <- input$values
    # This is required because ignoreNULL is set to `FALSE`. We set it to
    # false so that when all selected levels are removed from
    # covariateSelectLevels, the values are released "back to the pool".
    # When ignoreNULL is false, however, there are intermediate in the
    # reactivity cycle when input$values is NULL even though its value
    # hasn't changed.
    #
    # The latter situation hit me when I was trying to make "mutually
    # exclusive" categoricalSampleCovariateLevels that are populated
    # from the same categoricalCovariateSelect by using the .exclude
    # mojo
    if (unselected(selected.)) {
      selected. <- ""
    }
    if (!isTRUE(setequal(selected., state$values))) {
      ftrace("Change of selected input$values changes internal state from ",
             "`", isolate(state$values), "` ",
             "to `", selected., "`")
      state$values <- selected.
    }
  }, ignoreNULL = FALSE)

  values <- reactive(state$values)

  if (debug) {
    output$selected <- renderText(values())
  }

  vals <- list(
    values = values,
    levels = levels,
    .state = state,
    .ns = session$ns)
  class(vals) <- "CategoricalCovariateSelectLevels"
  return(vals)
}

#' @noRd
#' @importFrom shiny column fluidRow NS selectizeInput tags uiOutput
categoricalSampleCovariateLevelsMutexUI <- function(id, label1 = "Vals1",
                                                    label2 = "Vals2",
                                                    multiple1 = TRUE,
                                                    multiple2 = TRUE,
                                                    width = 4,
                                                    horizontal = TRUE, ...) {
  ns <- NS(id)

  assert_integerish(width, min.len = 1, max.len = 2)
  if (length(width) == 1L) width <- c(width, width)
  names(width) <- c("values1", "values2")

  vals <- list(values1 = list(label = label1, multiple = multiple1),
               values2 = list(label = label2, multiple = multiple2))

  # out <- sapply(names(vals), function(name) {
  #   ui <- selectizeInput(ns(name), choices = NULL,
  #                        label = vals[[name]][["label"]],
  #                        multiple = vals[[name]][["multiple"]])
  #   if (horizontal) {
  #     ui <- column(width[name], ui)
  #   }
  # })
  #
  # if (horizontal) {
  #   out <- fluidRow(out)
  # }

  out <- sapply(names(vals), function(name) {
    out <- uiOutput(ns(name))
    if (horizontal) {
      ui <- column(width[name], ui)
    }
  })

  if (horizontal) {
    out <- fluidRow(out)
  }

  out
}

# Update excluded covariates and levels =======================================

#' Updates the covariates/levels to be excluded from the universe.
#'
#' This should be s3, but for now we are essentially performing method dispatch
#' on the `type` parameter
#'
#' @noRd
#' @export
#' @param x Either the select- or level-module, or its internal `"state"`
#'   `reactiveValues` object.
update_exclude <- function(x, exclude, type, ...) {
  valid.x <- c("reactivevalues", "CategoricalCovariateSelect",
               "CategoricalCovariateSelectLevels")
  assert_multi_class(x, valid.x)
  if (!is.null(exclude)) assert_class(exclude, "reactive")

  if (is(x, "CategoricalCovariateSelect")) {
    type <- "covariate_select"
  } else if (is(x, "CategoricalCovariateSelectLevels")) {
    type <- "covariate_levels"
  }
  assert_choice(type, c("covariate_select", "covariate_levels"))

  if (is(x, "reactivevalues")) {
    state <- x
  } else if (test_multi_class(x, valid.x)) {
    state <- x[[".state"]]
  } else {
    stop("Unknown class type for x", class(x))
  }
  assert_class(state, "reactivevalues")

  if (type == "covariate_select") {
    # exclude is a tibble with variable and (optionally) value columns
    out <- tibble(variable = character())
    if (!is.null(exclude)) {
      exclude. <- exclude()
      if (is.character(exclude.)) {
        out <- tibble(variable = exclude.)
      } else {
        assert_multi_class(exclude., c("tbl", "data.frame"))
        assert_choice("variable", colnames(exclude.))
        out <- collect(exclude., n = Inf)
      }
    }
    out <- filter(out, !variable %in% c("", "__initializing__", "---"))
  } else if (type == "covariate_levels") {
    # exclude is a character vector
    out <- character()
    if (!is.null(exclude)) {
      out <- setdiff(exclude(), c("", "__initializing__", "---"))
    }
  } else {
    stop("update_exclude not implemented for: ", type)
  }

  # if (!setequal(state$exclude, out)) {
  #   state$exclude <- out
  # }
  state$exclude <- out
  invisible(x)
}

# Internal Helper Functions ====================================================

#' @noRd
.empty_covariate_summary <- function(.fds = NULL) {
  out <- tibble(
    variable = character(),
    class = character(),
    nsamples = integer(),
    level = character(),
    ninlevel = integer())
  if (!is.null(.fds)) {
    assert_facile_data_store(.fds)
    out <- as_facile_frame(out, .fds, .valid_sample_check = FALSE)
  }
  out
}
