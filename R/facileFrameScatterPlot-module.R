#' An interactive scatterplot module (2-3 dimensions) over a facile_frame.
#'
#' This module presents all of the numeric columns in x + internal quantitative
#' data for plotting, and categorical covariates for aesthetic mapping
#'
#' @export
#' @importFrom shiny column wellPanel
#' @importFrom plotly renderPlotly
#' @rdname facileScatterPlot
#'
#' @param ndim Defaults to 3. When any two dimensions are provided, a plot will
#'   be drawn, so provides both 2d and 3d functionality. If set to 2, then only
#'   2d functionality would be enabled.
facileFrameScatterPlot <- function(input, output, session, rfds, fframe, ...,
                              ndim = 3, x = NULL, y = NULL, z = NULL,
                              event_source = session$ns("selection"),
                              .reactive = TRUE) {
  assert_class(rfds, "ReactiveFacileDataStore")
  assesrt_class(fframe, "facile_frame")
  assert_int(ndim, lower = 2L, upper = 3L)
  ns <- session$ns

  isolate. <- if (.reactive) base::identity else shiny::isolate

  aes <- callModule(categoricalAestheticMap, "aes", rfds,
                    group = FALSE, ..., .reactive = .reactive)

  # Handle dynamic number of axes
  axnames <- head(c("x", "y", "z"), ndim)

  output$axes <- renderUI({
    ncol <- floor(12 / ndim)
    out <- sapply(axnames, function(axis) {
      column(ncol, wellPanel(assayFeatureSelectUI(ns(axis))))
    }, simplify = FALSE)
  })

  axes <- sapply(axnames, function(axis) {
    callModule(assayFeatureSelect, axis, rfds)
  }, simplify = FALSE)

  features <- reactive({
    lapply(axes, function(axis) {
      tryCatch(axis$features(), error = function(e) NULL)
    })
  })

  .ndim <- reactive({
    out <- 0L
    for (f in features()) {
      if (nrow(f) > 0L) out <- out + 1L
    }
    out
  })

  qcolnames <- reactive({
    out <- sapply(axes, name)
    out[!grepl("\\.nothing$", out)]
  })

  qlabels <- reactive({
    out <- sapply(axes, label)
    out[!grepl("^nothing$", out)]
  })

  # The quantitative data to plot, without aesthetic mappings
  rdat.core <- reactive({
    xdim <- .ndim()
    req(xdim >= 2L)
    f.all <- features()

    ftrace("Retrieving assay data for scatterplot")

    out <- active_samples(rfds)
    for (f in f.all) {
      if (nrow(f)) {
        out <- with_assay_data(out, f, aggregate = TRUE)
      }
    }
    out <- collect(out, n = Inf)
    colnames(out) <- c("dataset", "sample_id", qcolnames())
    out
  })

  rdat <- reactive({
    out <- req(rdat.core())
    aes.map <- aes$map()
    aes.covs <- setdiff(unlist(unname(aes.map)), colnames(out))
    if (length(aes.covs)) {
      ftrace("retrieving aes covariates for scatterplot")
      out <- with_sample_covariates(dat.core, aes.covs)
    }
    out
  })

  fscatter <- reactive({
    dat <- req(rdat())
    .axes <- qcolnames()
    .aes <- isolate(aes$map())
    .labels <- qlabels()
    ftrace("drawing scatterplot")
    fscatterplot(dat, .axes, color_aes = .aes$color, shape_aes = .aes$shape,
                 facet_aes = .aes$facet,
                 xlabel = .labels[1], # label(axes$x),
                 ylabel = .labels[2], # label(axes$y),
                 zlabel = .labels[3], # label(axes$z),
                 source = event_source)
  })

  output$scatter <- renderPlotly({
    fs <- fscatter()
    req(fs, "FacileScatterViz")
    plot(fs)
  })

  vals <- list(
    ndim = .ndim,
    xaxis = axes$x,
    yaxis = axes$y,
    zaxis = axes$z,
    aes = aes,
    viz = fscatter,
    .ns = session$ns)

  class(vals) <- c("FacileScatterPlot", "ReactiveFacileViz")
  vals
}

#' @export
#' @importFrom shiny column tagList wellPanel uiOutput
#' @importFrom plotly plotlyOutput
#' @rdname facileScatterPlot
facileFrameScatterPlot <- function(id, ...) {
  ns <- NS(id)
  tagList(
    fluidRow(
      uiOutput(ns("axes"))),
    fluidRow(
      column(
        12,
        wellPanel(categoricalAestheticMapUI(ns("aes"), group = FALSE)))),
    fluidRow(
      column(12, plotlyOutput(ns("scatter")))))
}

update_aes <- function(x, aesthethic, covariate, ...) {
  # TODO: enable callback/update of aesthetic map
}
