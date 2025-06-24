module {var:module_name} exposing (Model, Msg, init, update, view)

import Browser.Navigation as Nav
import Global exposing (GlobalStateGroupData)
import Html exposing (Html)


type alias Model =
    { global : GlobalStateGroupData
    }


type Msg
    = RedirectTo String


init : GlobalStateGroupData -> ( Model, Cmd Msg )
init global =
    ( { global = global }, Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        RedirectTo url ->
            ( model, Nav.pushUrl model.global.navKey url )


view : Model -> Html Msg
view model =
    Html.text "TODO: loggedInWithGroupPage:name}"
